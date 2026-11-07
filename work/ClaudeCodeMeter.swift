import Foundation

private let claudeActiveAge: TimeInterval = 20 * 60
private let claudeFinishedAge: TimeInterval = 120
private let claudeSpeedAge: TimeInterval = 20
private let claudeReadSize = 512 * 1024
private let claudeTailSize = 1024 * 1024
private let claudeUsageLineLimit = 8 * 1024 * 1024
private let claudeUsageEventName = Data("\"assistant\"".utf8)
private let claudeEventNames = [
    "assistant", "api-request", "user", "system", "custom-title", "relocated", "model"
].map { Data("\"\($0)\"".utf8) }
private let claudeFinishedReasons: Set<String> = ["end_turn", "stop_sequence", "refusal", "max_tokens"]
private let claudeTerminalEvents: Set<String> = ["turn_duration", "interrupted", "cancelled", "canceled"]
private let claudeModelEvents: Set<String> = ["model_changed", "model_change", "model_switch", "model_switched"]

private struct ClaudeResponse: Equatable {
    var time: Date
    var tokens: Int64

    func merging(_ response: Self) -> Self {
        Self(time: min(time, response.time), tokens: max(tokens, response.tokens))
    }
}

private struct ClaudeSpeed {
    var response: String
    var time: Date
    var tokens: Int64
    var elapsed: TimeInterval
    var rate: Double { Double(tokens) / elapsed }
}

private final class ClaudeTranscript {
    let session: String
    let isAgent: Bool
    var root: String
    var modified: Date
    var identity: NSObject?
    var liveIdentity: LiveLogFileStatus.Identity?
    var offset: UInt64 = 0
    var pending = Data()
    var droppingLine = false
    var available = true
    var cwd = ""
    var title = ""
    var started = false
    var endedAt: Date?
    var requests: [String: Date] = [:]
    var requestAt: Date?
    var userAt: Date?
    var turnStartedAt: Date?
    var lastResponse: (id: String, started: Date?)?
    var speed: ClaudeSpeed?
    var turnSpeeds: [String: ClaudeSpeed] = [:]
    var model: String?
    var modelAt: Date?
    var outputAt: Date?
    var responses: [String: ClaudeResponse] = [:]
    var changedResponses: Set<String>?

    init(url: URL, modified: Date, trackChanges: Bool = false) {
        session = url.deletingPathExtension().lastPathComponent.lowercased()
        let parent = url.deletingLastPathComponent()
        let inSubagents = parent.lastPathComponent == "subagents"
        isAgent = inSubagents || session.hasPrefix("agent-")
        root = Self.root(for: url)
        self.modified = modified
        changedResponses = trackChanges ? [] : nil
    }

    static func root(for url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        if folder.lastPathComponent == "subagents" {
            return folder.deletingLastPathComponent().lastPathComponent.lowercased()
        }
        return url.deletingPathExtension().lastPathComponent.lowercased()
    }

    var averageRate: Double? {
        let elapsed = turnSpeeds.values.reduce(0) { $0 + $1.elapsed }
        return elapsed > 0 ? turnSpeeds.values.reduce(0.0) { $0 + Double($1.tokens) } / elapsed : nil
    }

    func consume(_ chunk: Data, meter: ClaudeCodeMeter, usageOnly: Bool) {
        let lineLimit = usageOnly ? claudeUsageLineLimit : claudeReadSize
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let newline = chunk[start...].firstIndex(of: 10)
            let end = newline ?? chunk.endIndex
            if !droppingLine {
                if pending.isEmpty, let newline, end - start <= lineLimit {
                    apply(chunk[start..<newline], meter: meter, usageOnly: usageOnly)
                } else if pending.count + end - start <= lineLimit {
                    pending.append(contentsOf: chunk[start..<end])
                    if newline != nil { apply(pending, meter: meter, usageOnly: usageOnly) }
                } else {
                    pending.removeAll(keepingCapacity: false)
                    droppingLine = true
                }
            }
            guard let newline else { break }
            pending.removeAll(keepingCapacity: pending.count <= 64 * 1024)
            droppingLine = false
            start = chunk.index(after: newline)
        }
    }

    private func apply(_ line: Data, meter: ClaudeCodeMeter, usageOnly: Bool) {
        let header = line.prefix(768)
        let relevant = usageOnly ? line.range(of: claudeUsageEventName) != nil
            : claudeEventNames.contains(where: { header.range(of: $0) != nil })
        guard relevant,
              let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = event["type"] as? String else { return }
        let recordedSession = (event["sessionId"] as? String)?.lowercased()
        if isAgent {
            // Some agent logs inherit copies of the main conversation.
            if event["isSidechain"] as? Bool == false { return }
            if root == session, let recordedSession, UUID(uuidString: recordedSession) != nil { root = recordedSession }
        } else if UUID(uuidString: session) != nil, let recordedSession, recordedSession != session {
            return
        }

        if usageOnly {
            if type == "assistant" { recordUsage(event, meter: meter) }
            return
        }
        if let path = (event["relocatedCwd"] ?? event["cwd"]) as? String, !path.isEmpty { cwd = path }
        if type == "custom-title", let value = event["customTitle"] as? String {
            title = String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(140))
        }
        let subtype = event["subtype"] as? String ?? ""
        let time = meter.timestamp(event["timestamp"])
        if type == "model" || (type == "system" && claudeModelEvents.contains(subtype)) {
            updateModel(event["model"] ?? event["modelName"] ?? event["newModel"], at: time ?? modified)
        }
        guard let time else { return }
        switch type {
        case "api-request":
            if endedAt != nil { speed = nil }
            started = true
            endedAt = nil
            requestAt = time
            if let params = event["params"] as? [String: Any] { updateModel(params["model"], at: time) }
            if let id = event["id"] as? String {
                if requests.count >= 128 { requests = requests.filter { time.timeIntervalSince($0.value) <= claudeActiveAge } }
                if requests.count >= 128 { requests.removeAll(keepingCapacity: true) }
                requests[id] = time
            }
        case "assistant":
            recordSpeed(event, time: time)
        case "user":
            guard event["isMeta"] as? Bool != true else { return }
            if Self.isInterrupted(event) {
                if started { endedAt = time }
                return
            }
            if Self.isNewPrompt(event), time >= (turnStartedAt ?? .distantPast) {
                turnStartedAt = time
                turnSpeeds.removeAll(keepingCapacity: true)
                speed = nil
                lastResponse = nil
            }
            started = true
            endedAt = nil
            userAt = time
        case "system":
            if started && (claudeTerminalEvents.contains(subtype) ||
                           (subtype == "stop_hook_summary" && event["preventedContinuation"] as? Bool != true)) {
                endedAt = time
            }
        default:
            break
        }
    }

    private static func isNewPrompt(_ event: [String: Any]) -> Bool {
        guard event["sourceToolAssistantUUID"] == nil else { return false }
        let message = event["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]]
        return content?.contains { $0["type"] as? String == "tool_result" } != true
    }

    private func updateModel(_ value: Any?, at time: Date) {
        guard time >= (modelAt ?? .distantPast), let name = value as? String,
              !name.isEmpty, name != "<synthetic>", name != "synthetic" else { return }
        model = name
        modelAt = time
    }

    private static func isInterrupted(_ event: [String: Any]) -> Bool {
        let message = event["message"] as? [String: Any]
        let content = (message?["content"] as? [[String: Any]])?.first?["text"] as? String
            ?? message?["content"] as? String
        return content == "[Request interrupted by user]" || content == "[Request interrupted by user for tool use]"
    }

    private func recordSpeed(_ event: [String: Any], time: Date) {
        guard let message = event["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let id = message["id"] as? String ?? event["uuid"] as? String,
              let tokens = usage["output_tokens"] as? Int64, tokens >= 0,
              time >= (turnStartedAt ?? .distantPast) else { return }
        updateModel(message["model"] ?? event["requestedModel"], at: time)
        if tokens > 0 { outputAt = max(outputAt ?? time, time) }
        let sameResponse = lastResponse?.id == id
        let ref = event["requestRef"] as? String
        let exact = ref.flatMap { requests[$0] }
        let fallback = [requestAt, userAt].compactMap { $0 }
            .filter { $0 < time && $0 >= (speed?.time ?? .distantPast) }.max()
        let boundary = sameResponse ? lastResponse?.started : exact ?? fallback ?? speed?.time
        if !sameResponse, endedAt != nil { speed = nil }
        started = true
        lastResponse = (id, boundary)
        if let boundary, tokens > 0 {
            let elapsed = time.timeIntervalSince(boundary)
            if elapsed >= 0.25 && elapsed <= claudeActiveAge {
                let sample = ClaudeSpeed(response: id, time: time, tokens: tokens, elapsed: elapsed)
                if turnSpeeds[id].map({ $0.time > time }) != true { turnSpeeds[id] = sample }
                if speed.map({ $0.time > time }) != true { speed = sample }
            }
        }
        if let reason = message["stop_reason"] as? String, claudeFinishedReasons.contains(reason) {
            endedAt = time
        } else if !sameResponse {
            endedAt = nil
        }
    }

    private func recordUsage(_ event: [String: Any], meter: ClaudeCodeMeter) {
        guard let message = event["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let id = message["id"] as? String ?? event["uuid"] as? String,
              let time = meter.timestamp(event["timestamp"]) else { return }
        let fields = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
        let tokens = fields.compactMap { usage[$0] as? Int64 }
            .reduce(Int64(0)) { claudeSum($0, max(0, $1)) }
        guard tokens > 0 else { return }
        // All blocks of a streamed message belong to the day the response
        // was first logged. A repeat across midnight stays on its first day.
        let response = ClaudeResponse(time: time, tokens: tokens)
        let previous = responses[id]
        let updated = previous?.merging(response) ?? response
        guard updated != previous else { return }
        responses[id] = updated
        changedResponses?.insert(id)
    }

    func finishUsage(meter: ClaudeCodeMeter) {
        if !droppingLine, !pending.isEmpty {
            apply(pending, meter: meter, usageOnly: true)
        }
    }
}

private func claudeSum(_ left: Int64, _ right: Int64) -> Int64 {
    let (value, overflow) = left.addingReportingOverflow(right)
    return overflow ? Int64.max : value
}

final class ClaudeCodeMeter {
    private struct Group {
        var entries: [ClaudeTranscript] = []
        var root: ClaudeTranscript?
        var lastActivity: Date = .distantPast
    }

    static var claudeHome: URL {
        if let value = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    private let projects: URL
    private let manager = FileManager.default
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()
    private let workspaces = WorkspacePathResolver()
    private let desktopMetadata: ClaudeDesktopMetadata?
    private var live: [URL: ClaudeTranscript] = [:]
    private var nextLiveDiscovery = Date.distantPast
    private var liveDiscoveryAvailable = false
    private var daily: [URL: ClaudeTranscript] = [:]
    private var pendingDailyFiles: [URL: ClaudeTranscript] = [:]
    private var pendingDailyResponses: [String: ClaudeResponse] = [:]
    private var pendingUsageThrough = Date.distantPast

    init(home: URL = ClaudeCodeMeter.claudeHome) {
        let configured = home.appendingPathComponent("projects", isDirectory: true)
        self.projects = home.lastPathComponent == "projects" ? home : configured
        let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        desktopMetadata = projects.standardizedFileURL == standard.standardizedFileURL ? ClaudeDesktopMetadata() : nil
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    // Use separate instances for the speed and daily sampling queues.
    func sample(now: Date = Date()) -> MeterSnapshot {
        let discover = now >= nextLiveDiscovery
        // Check known transcripts on every sample without walking the entire
        // projects directory at the rate timer's frequency.
        if discover { nextLiveDiscovery = now.addingTimeInterval(0.45) }
        let sampled = scanLive(modifiedSince: now.addingTimeInterval(-claudeActiveAge), discover: discover)
        if discover { liveDiscoveryAvailable = sampled }
        let available = sampled && liveDiscoveryAvailable
        var groups: [String: Group] = [:]
        for file in live.values where file.started {
            var group = groups[file.root] ?? Group()
            group.entries.append(file)
            if !file.isAgent && (group.root?.modified ?? .distantPast) < file.modified { group.root = file }
            group.lastActivity = max(group.lastActivity, file.modified)
            groups[file.root] = group
        }
        if !groups.isEmpty { desktopMetadata?.refresh(now: now) }
        let rows: [(row: MeterRow, time: Date)] = groups.compactMap { id, group in
            let parent = group.root
            let active = parent?.endedAt == nil && group.entries.contains { $0.endedAt == nil }
            let latestEnd = parent?.endedAt ?? group.entries.lazy.compactMap(\.endedAt).max()
            guard active || latestEnd.map({ now.timeIntervalSince($0) <= claudeFinishedAge }) == true else { return nil }
            var speeds: [String: ClaudeSpeed] = [:]
            for file in group.entries where file.endedAt == nil {
                if let speed = file.speed, speed.time <= now, now.timeIntervalSince(speed.time) <= claudeSpeedAge {
                    speeds[speed.response] = speed
                }
            }
            let rate = active
                ? (speeds.isEmpty ? nil : speeds.values.reduce(0) { $0 + $1.rate })
                : parent?.speed?.rate ?? group.entries.lazy.compactMap(\.speed).max(by: { $0.time < $1.time })?.rate
            let state: MeterState = active ? (rate == nil ? .waiting : .generating) : .finished
            let item = parent ?? group.entries.max(by: { $0.modified < $1.modified })
            let metadata = desktopMetadata?.sessions[id]
            let title = item?.title.isEmpty == false ? item?.title ?? "" : metadata?.title ?? ""
            let cwd = metadata?.cwd.isEmpty == false ? metadata?.cwd ?? "" : item?.cwd ?? ""
            let outputAt = item?.outputAt.flatMap { $0 <= now ? $0 : nil }
                ?? group.entries.lazy.compactMap(\.outputAt).filter { $0 <= now }.max()
            return (MeterRow(id: id, title: title.isEmpty ? "对话 · \(id.suffix(6))" : title,
                             rate: rate, state: state, project: workspaces.project(for: cwd),
                             model: item?.model, outputAt: outputAt, averageRate: item?.averageRate), group.lastActivity)
        }
        let ordered = rows.sorted { left, right in
            left.time == right.time ? left.row.id < right.row.id : left.time > right.time
        }
        return MeterSnapshot(rows: ordered.map(\.row), sourceAvailable: available)
    }

    func sampleDaily(now: Date = Date()) -> DailyTokenSnapshot {
        guard let interval = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: now) else {
            return DailyTokenSnapshot(total: 0, complete: false)
        }
        let cutoff = min(interval.start, now.addingTimeInterval(-claudeActiveAge))
        let (unique, complete) = dailyResponses(modifiedSince: cutoff)
        let total = unique.values.lazy.filter { $0.time >= interval.start && $0.time <= now }
            .reduce(Int64(0)) { claudeSum($0, $1.tokens) }
        return DailyTokenSnapshot(total: total, complete: complete)
    }

    func sampleUsageEvents(now: Date = Date()) -> (events: [HistoryUsageEvent], complete: Bool) {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let (unique, complete) = dailyResponses(modifiedSince: yesterday)
        let events = unique.compactMap { id, response -> HistoryUsageEvent? in
            guard response.time >= yesterday, response.time <= now else { return nil }
            return HistoryUsageEvent(id: id, time: response.time, tokens: response.tokens)
        }
        return (events, complete)
    }

    // The daily queue acknowledges only successful ledger transactions. Keep
    // pending responses independently of their files until then.
    func samplePendingUsageEvents(now: Date) -> (events: [HistoryUsageEvent], complete: Bool) {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let complete = scanDaily(files: &pendingDailyFiles, modifiedSince: yesterday, trackChanges: true)
        var changed: Set<String> = []
        for transcript in pendingDailyFiles.values {
            if let dirty = transcript.changedResponses, !dirty.isEmpty {
                changed.formUnion(dirty)
                transcript.changedResponses = []
            }
        }
        for id in changed {
            var merged = pendingDailyResponses[id]
            for transcript in pendingDailyFiles.values {
                guard let response = transcript.responses[id] else { continue }
                merged = merged?.merging(response) ?? response
            }
            if let merged, merged.time >= yesterday || pendingDailyResponses[id] != nil {
                pendingDailyResponses[id] = merged
            }
        }
        pendingUsageThrough = now
        let events = pendingDailyResponses.compactMap { id, response -> HistoryUsageEvent? in
            guard response.time <= now else { return nil }
            return HistoryUsageEvent(id: id, time: response.time, tokens: response.tokens)
        }
        return (events, complete)
    }

    func didPersistPendingUsage() {
        pendingDailyResponses = pendingDailyResponses.filter { $0.value.time > pendingUsageThrough }
    }

    // Stream each archive file and report usage fields only. The history store
    // deduplicates identical responses across files, including relocated logs.
    func scanHistory(
        through: Date,
        shouldRead: (HistoryLogRevision) -> Bool,
        shouldCancel: () -> Bool,
        receive: (HistoryLogRevision, [HistoryUsageEvent]) -> Void
    ) -> Bool {
        guard !shouldCancel() else { return false }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey
        ]
        var complete = true
        guard manager.isReadableFile(atPath: projects.path),
              let entries = manager.enumerator(at: projects, includingPropertiesForKeys: Array(keys),
                  options: [.skipsHiddenFiles], errorHandler: { _, _ in complete = false; return true })
        else { return false }

        var files: [HistoryLogRevision] = []
        for case let url as URL in entries where url.pathExtension == "jsonl" {
            if shouldCancel() { return false }
            guard let attributes = try? url.resourceValues(forKeys: keys),
                  let size = attributes.fileSize, size >= 0,
                  let modified = attributes.contentModificationDate else {
                complete = false
                continue
            }
            guard attributes.isRegularFile == true else { continue }
            let identity = (attributes.fileResourceIdentifier as? Data)?.base64EncodedString() ?? ""
            let revision = HistoryLogRevision(url: url, modified: modified, size: UInt64(size), identity: identity)
            if shouldRead(revision) { files.append(revision) }
        }
        for revision in files.sorted(by: { $0.modified > $1.modified }) {
            if shouldCancel() { return false }
            let imported = autoreleasepool {
                let transcript = ClaudeTranscript(url: revision.url, modified: revision.modified)
                guard read(revision.url, size: revision.size, into: transcript, usageOnly: true, shouldCancel: shouldCancel)
                else { return false }
                transcript.finishUsage(meter: self)
                guard !shouldCancel() else { return false }
                let events = transcript.responses.compactMap { id, response -> HistoryUsageEvent? in
                    guard response.time <= through else { return nil }
                    return HistoryUsageEvent(id: id, time: response.time, tokens: response.tokens)
                }
                receive(revision, events)
                return true
            }
            complete = complete && imported
        }
        return complete && !shouldCancel()
    }

    private func dailyResponses(modifiedSince cutoff: Date) -> ([String: ClaudeResponse], Bool) {
        let complete = scanDaily(files: &daily, modifiedSince: cutoff)
        var unique: [String: ClaudeResponse] = [:]
        for transcript in daily.values {
            unique.merge(transcript.responses) { $0.merging($1) }
        }
        return (unique, complete)
    }

    fileprivate func timestamp(_ value: Any?) -> Date? {
        guard let stamp = value as? String else { return nil }
        return fractional.date(from: stamp) ?? whole.date(from: stamp)
    }

    private func scanLive(modifiedSince cutoff: Date, discover: Bool) -> Bool {
        var available = manager.isReadableFile(atPath: projects.path)
        guard available else {
            live.removeAll()
            return false
        }

        if !discover {
            for (url, previous) in live {
                let file = refreshLiveFile(url, previous: previous, modifiedSince: cutoff)
                if file !== previous { live[url] = file }
                available = available && (file?.available ?? true)
            }
            return available
        }

        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = manager.enumerator(at: projects, includingPropertiesForKeys: Array(keys),
              options: [.skipsHiddenFiles], errorHandler: { _, _ in available = false; return true }) else {
            live.removeAll()
            return false
        }
        var discovered: [URL: ClaudeTranscript] = [:]
        discovered.reserveCapacity(live.count)
        for case let url as URL in entries where url.pathExtension == "jsonl" {
            guard let attributes = try? url.resourceValues(forKeys: keys),
                  let modified = attributes.contentModificationDate else {
                available = false
                continue
            }
            guard attributes.isRegularFile == true, modified >= cutoff,
                  let file = refreshLiveFile(url, previous: live[url], modifiedSince: cutoff) else { continue }
            discovered[url] = file
            available = available && file.available
        }
        live = discovered
        return available
    }

    private func refreshLiveFile(_ url: URL, previous: ClaudeTranscript?, modifiedSince cutoff: Date) -> ClaudeTranscript? {
        guard let status = LiveLogFileStatus(url), status.modified >= cutoff else { return nil }
        var file = previous ?? ClaudeTranscript(url: url, modified: status.modified)
        if file.offset > status.size || (file.liveIdentity != nil && file.liveIdentity != status.identity) {
            file = ClaudeTranscript(url: url, modified: status.modified)
        }
        file.liveIdentity = status.identity
        file.modified = status.modified
        if file.offset < status.size { file.available = read(url, size: status.size, into: file, usageOnly: false) }
        return file
    }

    private func scanDaily(
        files: inout [URL: ClaudeTranscript], modifiedSince cutoff: Date, trackChanges: Bool = false
    ) -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey, .fileResourceIdentifierKey]
        var available = manager.isReadableFile(atPath: projects.path)
        var candidates: [URL: (modified: Date, size: UInt64, identity: NSObject?)] = [:]
        var recentRoots: Set<String> = []
        var recentProjects: Set<URL> = []
        guard available, let entries = manager.enumerator(at: projects, includingPropertiesForKeys: Array(keys),
              options: [.skipsHiddenFiles], errorHandler: { _, _ in available = false; return true }) else {
            files.removeAll()
            return false
        }
        for case let url as URL in entries where url.pathExtension == "jsonl" {
            guard let attributes = try? url.resourceValues(forKeys: keys),
                  let modified = attributes.contentModificationDate, let size = attributes.fileSize else {
                available = false
                continue
            }
            guard attributes.isRegularFile == true else { continue }
            candidates[url] = (modified, UInt64(size), attributes.fileResourceIdentifier as? NSObject)
            if modified >= cutoff {
                recentRoots.insert(files[url]?.root ?? ClaudeTranscript.root(for: url))
                let folder = url.deletingLastPathComponent()
                let project = folder.lastPathComponent == "subagents"
                    ? folder.deletingLastPathComponent().deletingLastPathComponent() : folder
                recentProjects.insert(project)
            }
        }
        var paths: Set<URL> = []
        for (url, attributes) in candidates {
            let (modified, size, identity) = attributes
            if modified < cutoff {
                let root = files[url]?.root ?? ClaudeTranscript.root(for: url)
                let legacyAgent = url.lastPathComponent.hasPrefix("agent-")
                    && recentProjects.contains(url.deletingLastPathComponent())
                guard recentRoots.contains(root) || legacyAgent else { continue }
            }
            paths.insert(url)
            var file = files[url] ?? ClaudeTranscript(url: url, modified: modified, trackChanges: trackChanges)
            if file.offset > size || (file.identity != nil && file.identity != identity) {
                file = ClaudeTranscript(url: url, modified: modified, trackChanges: trackChanges)
            }
            file.identity = identity
            file.modified = modified
            if file.offset < size { file.available = read(url, size: size, into: file, usageOnly: true) }
            files[url] = file
            available = available && file.available
        }
        files = files.filter { paths.contains($0.key) }
        return available
    }

    private func read(
        _ url: URL, size: UInt64, into file: ClaudeTranscript, usageOnly: Bool, shouldCancel: () -> Bool = { false }
    ) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            if !usageOnly && file.offset == 0 && size > UInt64(claudeTailSize) {
                file.offset = size - UInt64(claudeTailSize)
                file.droppingLine = true
            }
            try handle.seek(toOffset: file.offset)
            while file.offset < size {
                if shouldCancel() { return false }
                let count = Int(min(size - file.offset, UInt64(claudeReadSize)))
                let readChunk = try autoreleasepool {
                    guard let data = try handle.read(upToCount: count), !data.isEmpty else { return false }
                    file.consume(data, meter: self, usageOnly: usageOnly)
                    file.offset += UInt64(data.count)
                    return true
                }
                guard readChunk else { return false }
            }
            return true
        } catch {
            return false
        }
    }
}

private final class ClaudeDesktopMetadata {
    struct Entry {
        var title: String
        var cwd: String
        var modified: Date
    }

    private let manager = FileManager.default
    private var nextRefresh = Date.distantPast
    private(set) var sessions: [String: Entry] = [:]

    func refresh(now: Date) {
        guard now >= nextRefresh else { return }
        nextRefresh = now.addingTimeInterval(20)
        let support = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        var latest: [String: Entry] = [:]
        for app in ["Claude", "Claude-3p"] {
            let root = support.appendingPathComponent(app).appendingPathComponent("claude-code-sessions")
            guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                   options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in entries where url.pathExtension == "json" {
                guard let props = try? url.resourceValues(forKeys: keys),
                      let size = props.fileSize, size <= claudeReadSize,
                      let modified = props.contentModificationDate,
                      let data = try? Data(contentsOf: url),
                      let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let id = (item["cliSessionId"] as? String)?.lowercased(),
                      latest[id].map({ $0.modified >= modified }) != true else { continue }
                let title = (item["title"] as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let cwd = item["originCwd"] as? String ?? item["cwd"] as? String ?? ""
                latest[id] = Entry(title: String(title.prefix(140)), cwd: cwd, modified: modified)
            }
        }
        sessions = latest
    }
}
