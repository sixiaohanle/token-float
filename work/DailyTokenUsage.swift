import Foundation

struct DailyTokenSnapshot: Equatable {
    var total: Int64
    var complete: Bool
}

private struct UsageTurn: Hashable {
    var thread: String
    var turn: String

    var historyGroup: String { "\(thread.utf8.count):\(thread)\(turn)" }
}

private struct UsageKey: Hashable {
    var thread: String
    var event: String

    var historyID: String { "\(thread.utf8.count):\(thread)\(event)" }
}

private struct RecordedUsage: Equatable {
    var turn: UsageTurn
    var tokens: Int64
    var time: Date
    var supersededTurns: Set<UsageTurn> = []

    func merged(with other: RecordedUsage) -> RecordedUsage {
        RecordedUsage(
            turn: turn, tokens: max(tokens, other.tokens), time: min(time, other.time),
            supersededTurns: supersededTurns.union(other.supersededTurns)
        )
    }
}

private let dailyLineLimit = 512 * 1024
private let dailyHeaders = ["session_meta", "token_usage_record", "token_count", "task_started", "turn_started"]
    .map { Data("\"\($0)\"".utf8) }

private final class DailyUsageFile {
    let compressed: Bool
    var offset: UInt64 = 0
    var modified: Date?
    var identity: NSObject?
    var finished = false
    var readable = true
    var thread: String
    var turn = ""
    var sourceOrdinal: Int?
    var forkStart: Date?
    var inheritedTurn = false
    var hasMetadata = false
    var cumulative: Int64?
    var pending = Data()
    var droppingLine = false
    var modernTurns: Set<UsageTurn> = []
    var responses: [UsageKey: RecordedUsage] = [:]
    var legacy: [UsageKey: RecordedUsage] = [:]
    private var pendingSince: Date?
    private var pendingResponses: Set<UsageKey> = []
    private var pendingLegacy: Set<UsageKey> = []

    init(url: URL) {
        compressed = url.pathExtension == "zst"
        let rollout = compressed ? url.deletingPathExtension() : url
        thread = String(rollout.deletingPathExtension().lastPathComponent.suffix(36))
    }

    func consume(_ chunk: Data, before end: Date, clock: UsageClock) {
        chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let newline = memchr(base.advanced(by: offset), 10, bytes.count - offset)
                let lineEnd = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
                let start = chunk.startIndex + offset
                let stop = chunk.startIndex + lineEnd
                if !droppingLine {
                    if pending.isEmpty, newline != nil, lineEnd - offset <= dailyLineLimit {
                        apply(chunk[start..<stop], before: end, clock: clock)
                    } else if pending.count + lineEnd - offset <= dailyLineLimit {
                        pending.append(contentsOf: chunk[start..<stop])
                        if newline != nil { apply(pending, before: end, clock: clock) }
                    } else {
                        droppingLine = true
                        pending.removeAll()
                    }
                }
                guard newline != nil else { break }
                pending.removeAll(keepingCapacity: pending.count <= 16 * 1024)
                droppingLine = false
                offset = lineEnd + 1
            }
        }
    }

    private func apply(_ line: Data, before end: Date, clock: UsageClock) {
        let header = line.prefix(384)
        guard dailyHeaders.contains(where: { header.range(of: $0) != nil }),
              let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = event["type"] as? String,
              let payload = event["payload"] as? [String: Any] else { return }

        if type == "session_meta" {
            guard !hasMetadata else { return }
            hasMetadata = true
            thread = payload["id"] as? String ?? thread
            sourceOrdinal = (payload["subagent_history_start_ordinal"] as? Int)
                ?? (payload["forked_from_ordinal_exclusive"] as? Int)
            if sourceOrdinal == nil, payload["forked_from_id"] != nil, let stamp = event["timestamp"] as? String {
                forkStart = clock.parse(stamp)
            }
            return
        }
        let ordinal = event["ordinal"] as? Int
        if let sourceOrdinal, let ordinal, ordinal < sourceOrdinal { return }
        let name = payload["type"] as? String
        if type == "event_msg", name == "task_started" || name == "turn_started" {
            turn = payload["turn_id"] as? String ?? turn
            // Older forks copied prior turns and rewrote the event timestamp, while
            // retaining the original Unix start time in the lifecycle payload.
            if let forkStart, let startedAt = payload["started_at"] as? Double {
                inheritedTurn = startedAt < floor(forkStart.timeIntervalSince1970)
            }
            return
        }
        guard let stamp = event["timestamp"] as? String, let time = clock.parse(stamp), time < end else { return }

        if type == "token_usage_record" {
            if let owner = payload["thread_id"] as? String, owner != thread { return }
            guard let tokens = Self.total(payload["usage"]) else { return }
            let usageTurn = UsageTurn(thread: thread, turn: payload["turn_id"] as? String ?? turn)
            let supersededTurns: Set = [usageTurn, UsageTurn(thread: thread, turn: turn)]
            modernTurns.formUnion(supersededTurns)
            let id = payload["response_id"] as? String ?? "\(stamp):\(ordinal ?? 0)"
            let key = UsageKey(thread: thread, event: id)
            let usage = RecordedUsage(turn: usageTurn, tokens: tokens, time: time, supersededTurns: supersededTurns)
            let updated = responses[key]?.merged(with: usage) ?? usage
            if responses[key] != updated {
                responses[key] = updated
                if let pendingSince, updated.time >= pendingSince { pendingResponses.insert(key) }
            }
            return
        }

        guard type == "event_msg", name == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = Self.total(info["total_token_usage"]) else { return }
        let batch = Self.total(info["last_token_usage"])
        let before = cumulative
        cumulative = total
        let change = before.map { total >= $0 ? total - $0 : batch ?? 0 } ?? batch ?? 0
        let delta = min(change, batch ?? change)
        let usageTurn = UsageTurn(thread: thread, turn: turn)
        // Legacy snapshots can lag or use a different cumulative counter.
        guard delta > 0, !inheritedTurn else { return }

        // Older logs can be copied verbatim when a session is archived.
        let key = UsageKey(thread: thread, event: "\(stamp):\(total)")
        let updated = RecordedUsage(turn: usageTurn, tokens: delta, time: time)
        if legacy[key] != updated {
            legacy[key] = updated
            if let pendingSince, time >= pendingSince { pendingLegacy.insert(key) }
        }
    }

    func historyEvents(since start: Date = .distantPast) -> [HistoryUsageEvent] {
        responses.compactMap { key, usage in Self.historyEvent(key, usage, since: start, modern: true) }
            + legacy.compactMap { key, usage in Self.historyEvent(key, usage, since: start, modern: false) }
    }

    func trackPendingUsage(since start: Date) {
        if pendingSince == nil {
            for (key, usage) in responses where usage.time >= start { pendingResponses.insert(key) }
            for (key, usage) in legacy where usage.time >= start { pendingLegacy.insert(key) }
        }
        pendingSince = start
    }

    func takePendingUsage() -> [HistoryUsageEvent] {
        guard let pendingSince, !pendingResponses.isEmpty || !pendingLegacy.isEmpty else { return [] }
        defer {
            pendingResponses.removeAll()
            pendingLegacy.removeAll()
        }
        let modern = pendingResponses.compactMap { key in
            responses[key].flatMap { Self.historyEvent(key, $0, since: pendingSince, modern: true) }
        }
        let fallback = pendingLegacy.compactMap { key in
            legacy[key].flatMap { Self.historyEvent(key, $0, since: pendingSince, modern: false) }
        }
        return modern + fallback
    }

    private static func historyEvent(
        _ key: UsageKey, _ usage: RecordedUsage, since start: Date, modern: Bool
    ) -> HistoryUsageEvent? {
        guard usage.time >= start else { return nil }
        if modern {
            return HistoryUsageEvent(
                id: "response:\(key.historyID)", time: usage.time, tokens: usage.tokens,
                supersedesLegacy: usage.supersededTurns.map(\.historyGroup).sorted()
            )
        }
        return HistoryUsageEvent(
            id: "legacy:\(key.historyID)", time: usage.time, tokens: usage.tokens, legacyGroup: usage.turn.historyGroup
        )
    }

    func finishHistory(before end: Date, clock: UsageClock) {
        if !droppingLine, !pending.isEmpty {
            apply(pending, before: end, clock: clock)
        }
    }

    private static func total(_ value: Any?) -> Int64? {
        guard let usage = value as? [String: Any] else { return nil }
        if let total = usage["total_tokens"] as? Int64, total >= 0 { return total }
        guard let input = usage["input_tokens"] as? Int64, input >= 0,
              let output = usage["output_tokens"] as? Int64, output >= 0,
              input <= Int64.max - output else { return nil }
        return input + output
    }
}

private final class UsageClock {
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()

    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parse(_ stamp: String) -> Date? {
        fractional.date(from: stamp) ?? whole.date(from: stamp)
    }
}

final class DailyTokenUsage {
    private let home: URL
    private let fileManager = FileManager.default
    private let clock = UsageClock()
    private var day: DateInterval?
    private var files: [URL: DailyUsageFile] = [:]
    private var pendingUsageEvents: [String: HistoryUsageEvent] = [:]

    init(home: URL = CodexMeter.codexHome) {
        self.home = home
    }

    // Read on a separate queue so a cold scan does not delay the speed display.
    func sample(now: Date = Date()) -> DailyTokenSnapshot {
        guard let today = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: now) else {
            return DailyTokenSnapshot(total: 0, complete: false)
        }
        let cutoff = min(today.start, now.addingTimeInterval(-20 * 60))
        let complete = refreshFiles(for: today, modifiedSince: cutoff)
        var modernTurns: Set<UsageTurn> = []
        var responses: [UsageKey: RecordedUsage] = [:]
        var legacy: [UsageKey: RecordedUsage] = [:]
        for file in files.values {
            modernTurns.formUnion(file.modernTurns)
            responses.merge(file.responses) { $0.merged(with: $1) }
            legacy.merge(file.legacy) { $0.merged(with: $1) }
        }

        var total: Int64 = 0
        for usage in responses.values where usage.time >= today.start {
            total = Self.adding(total, usage.tokens)
        }
        for usage in legacy.values where usage.time >= today.start && !modernTurns.contains(usage.turn) {
            total = Self.adding(total, usage.tokens)
        }
        return DailyTokenSnapshot(total: total, complete: complete)
    }

    func sampleUsageEvents(now: Date) -> (events: [HistoryUsageEvent], complete: Bool) {
        let calendar = Calendar.autoupdatingCurrent
        guard let today = calendar.dateInterval(of: .day, for: now),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: today.start) else {
            return ([], false)
        }
        let complete = refreshFiles(for: today, modifiedSince: yesterday)
        return (files.values.filter(\.readable).flatMap { $0.historyEvents(since: yesterday) }, complete)
    }

    // The serial daily sampler retains deltas across log rotation or midnight
    // until their SQLite transaction succeeds.
    func samplePendingUsageEvents(now: Date) -> (events: [HistoryUsageEvent], complete: Bool) {
        let calendar = Calendar.autoupdatingCurrent
        guard let today = calendar.dateInterval(of: .day, for: now),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: today.start) else {
            return (Array(pendingUsageEvents.values), false)
        }
        let complete = refreshFiles(for: today, modifiedSince: yesterday, pendingSince: yesterday)
        for file in files.values where file.readable {
            for event in file.takePendingUsage() {
                if let pending = pendingUsageEvents[event.id] {
                    pendingUsageEvents[event.id] = HistoryUsageEvent(
                        id: event.id, time: min(pending.time, event.time), tokens: max(pending.tokens, event.tokens),
                        legacyGroup: pending.legacyGroup ?? event.legacyGroup,
                        supersedesLegacy: Set(pending.supersedesLegacy).union(event.supersedesLegacy).sorted()
                    )
                } else {
                    pendingUsageEvents[event.id] = event
                }
            }
        }
        return (Array(pendingUsageEvents.values), complete)
    }

    func didPersistPendingUsage() {
        pendingUsageEvents.removeAll()
    }

    // Historical reads use independent cursors and only publish files that were fully read.
    func scanHistory(
        through: Date,
        shouldRead: (HistoryLogRevision) -> Bool,
        shouldCancel: () -> Bool,
        receive: (HistoryLogRevision, [HistoryUsageEvent]) -> Void
    ) -> Bool {
        guard let end = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: through)?.end else {
            return false
        }
        let inventory = inventory(modifiedSince: .distantPast)
        var complete = inventory.complete
        for revision in inventory.revisions.sorted(by: { $0.modified > $1.modified }) {
            if shouldCancel() { return false }
            guard shouldRead(revision) else { continue }
            let imported = autoreleasepool {
                let file = DailyUsageFile(url: revision.url)
                guard read(revision, into: file, before: end, shouldCancel: shouldCancel) else { return false }
                file.finishHistory(before: end, clock: clock)
                receive(revision, file.historyEvents())
                return true
            }
            complete = complete && imported
        }
        return complete && !shouldCancel()
    }

    private func refreshFiles(for today: DateInterval, modifiedSince cutoff: Date, pendingSince: Date? = nil) -> Bool {
        if day != today {
            day = today
            files.removeAll()
        }
        let inventory = inventory(modifiedSince: cutoff)
        var complete = inventory.complete
        for revision in inventory.revisions {
            let url = revision.url
            var file = files[url] ?? DailyUsageFile(url: url)
            let identity = revision.identity as NSString
            let replaced = file.identity != nil && identity != file.identity
            let rewritten = file.offset == revision.size && file.modified != revision.modified
            if replaced || rewritten || (file.compressed && (file.modified != revision.modified || !file.readable))
                || file.offset > revision.size {
                file = DailyUsageFile(url: url)
            }
            files[url] = file
            file.identity = identity
            if let pendingSince { file.trackPendingUsage(since: pendingSince) }
            if file.compressed ? !file.finished : file.offset < revision.size {
                file.readable = read(revision, into: file, before: today.end, shouldCancel: { false })
            }
            file.modified = revision.modified
            complete = complete && file.readable
        }
        return complete
    }

    private func inventory(modifiedSince cutoff: Date) -> (revisions: [HistoryLogRevision], complete: Bool) {
        var revisions: [HistoryLogRevision] = []
        var complete = true
        var foundDirectory = false
        for directory in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(directory, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path) else { continue }
            foundDirectory = true
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey, .fileResourceIdentifierKey]
            guard let entries = fileManager.enumerator(
                at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
                errorHandler: { _, _ in complete = false; return true }
            ) else {
                complete = false
                continue
            }

            for case let url as URL in entries {
                guard url.pathExtension == "jsonl" || url.lastPathComponent.hasSuffix(".jsonl.zst") else { continue }
                guard let properties = try? url.resourceValues(forKeys: keys), let modified = properties.contentModificationDate,
                      let size = properties.fileSize else {
                    complete = false
                    continue
                }
                guard properties.isRegularFile == true, modified >= cutoff else { continue }
                let identity = (properties.fileResourceIdentifier as? Data)?.base64EncodedString() ?? ""
                revisions.append(HistoryLogRevision(url: url, modified: modified, size: UInt64(size), identity: identity))
            }
        }
        return (revisions, complete && foundDirectory)
    }

    private static func adding(_ total: Int64, _ delta: Int64) -> Int64 {
        let (sum, overflow) = total.addingReportingOverflow(delta)
        return overflow ? Int64.max : sum
    }

    private func read(
        _ revision: HistoryLogRevision, into file: DailyUsageFile, before end: Date, shouldCancel: () -> Bool
    ) -> Bool {
        if file.compressed {
            return readCompressed(revision.url, into: file, before: end, shouldCancel: shouldCancel)
        }
        guard let handle = try? FileHandle(forReadingFrom: revision.url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: file.offset)
            while file.offset < revision.size {
                let count = Int(min(revision.size - file.offset, 512 * 1024))
                let readChunk = try autoreleasepool {
                    guard !shouldCancel(), let data = try handle.read(upToCount: count), !data.isEmpty else { return false }
                    file.consume(data, before: end, clock: clock)
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

    private func readCompressed(
        _ url: URL, into file: DailyUsageFile, before end: Date, shouldCancel: () -> Bool
    ) -> Bool {
        let search = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        guard let executable = search.first(where: fileManager.isExecutableFile(atPath:)) else { return false }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-d", "-c", "--", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            while true {
                if shouldCancel() {
                    process.terminate()
                    process.waitUntilExit()
                    return false
                }
                let readChunk = try autoreleasepool {
                    guard let data = try output.fileHandleForReading.read(upToCount: 512 * 1024), !data.isEmpty else {
                        return false
                    }
                    file.consume(data, before: end, clock: clock)
                    return true
                }
                if !readChunk { break }
            }
            process.waitUntilExit()
            file.finished = process.terminationStatus == 0
            return file.finished
        } catch {
            if process.isRunning { process.terminate() }
            return false
        }
    }
}
