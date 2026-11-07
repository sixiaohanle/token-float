import Foundation
import SQLite3

enum MeterState {
    case generating, waiting, finished
}

struct MeterRow: Identifiable {
    var id: String
    var title: String
    var rate: Double?
    var state: MeterState
    var project: String = "其他工作区"
    var model: String?
    var outputAt: Date?
    var averageRate: Double?
    var totalTokens: Int64?
}

struct MeterSnapshot {
    var rows: [MeterRow]
    var sourceAvailable: Bool
}

private let freshSampleAge: TimeInterval = 20
private let finishedVisibility: TimeInterval = 120
private let activeTimeout: TimeInterval = 20 * 60
private let tailSize = 1024 * 1024
private let maxLineSize = 512 * 1024
private let toolResultTypes = ["function_call_output", "custom_tool_call_output"]
private let monitoredEvents = [
    "session_meta", "token_usage_record", "token_count", "item_completed", "task_started",
    "task_complete", "turn_aborted", "turn_started", "turn_completed", "turn_context",
    "thread_settings_applied", "model_rerouted"
] + toolResultTypes
private let monitoredHeaders = monitoredEvents.map { Data("\"\($0)\"".utf8) }

private struct SpeedSample {
    var time: Date
    var rate: Double
}

private final class Rollout {
    let url: URL
    var id: String
    var parentID: String?
    var workspacePath: String?
    var readMetadata = false
    var firstOwnOrdinal: Int?
    var isFork = false
    var lastModified: Date
    var offset: UInt64 = 0
    var inode: UInt64?
    var pending = Data()
    var skippingLine = false
    var turnID: String?
    var endedAt: Date?
    var started = false
    var cumulativeOutput: Int?
    var seenResponses: Set<String> = []
    var hasModernUsageInTurn = false
    var conversationTokens: Int64?
    var model: String?
    var modelAt: Date?
    var outputAt: Date?
    var measuredOutput = 0.0
    var measuredSeconds = 0.0
    var turnStartedAt: Date?
    var requestBoundaryAt: Date?
    var firstOutputAt: Date?
    var lastUsageAt: Date?
    var latestSpeed: SpeedSample?

    init(url: URL, modified: Date) {
        self.url = url
        self.lastModified = modified
        self.id = String(url.deletingPathExtension().lastPathComponent.suffix(36))
    }

    func apply(_ line: Data, clock: RolloutClock) {
        // Only interpret session metadata, usage and lifecycle records.
        let header = line.prefix(384)
        guard monitoredHeaders.contains(where: { header.range(of: $0) != nil }),
        let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
        let type = event["type"] as? String,
        let payload = event["payload"] as? [String: Any] else { return }

        if type == "session_meta" {
            guard !readMetadata else { return }
            readMetadata = true
            id = payload["id"] as? String ?? id
            let source = payload["source"] as? [String: Any]
            let agent = source?["subagent"] as? [String: Any]
            let spawn = agent?["thread_spawn"] as? [String: Any]
            parentID = payload["parent_thread_id"] as? String ?? spawn?["parent_thread_id"] as? String ?? parentID
            workspacePath = payload["cwd"] as? String
                ?? (payload["runtime_workspace_roots"] as? [String])?.first
            firstOwnOrdinal = payload["subagent_history_start_ordinal"] as? Int
            isFork = payload["forked_from_id"] as? String != nil && parentID == nil
            return
        }

        if let firstOwnOrdinal, let ordinal = event["ordinal"] as? Int, ordinal < firstOwnOrdinal { return }
        guard let timestamp = event["timestamp"] as? String, let time = clock.parse(timestamp) else { return }
        let name = payload["type"] as? String
        if type == "model_rerouted" {
            observeModel(payload["to_model"] ?? payload["toModel"] ?? payload["to"], at: time)
            return
        }
        if type == "turn_context" || (type == "response_item" && toolResultTypes.contains(name ?? "")) {
            if type == "turn_context" { observeModel(payload["model"], at: time) }
            requestBoundaryAt = time
            return
        }
        if type == "event_msg" {
            switch name {
            case "task_started", "turn_started":
                let nextTurn = payload["turn_id"] as? String
                if started, endedAt == nil, let nextTurn, turnID == nextTurn { return }
                started = true
                turnID = nextTurn
                endedAt = nil
                turnStartedAt = time
                requestBoundaryAt = nil
                firstOutputAt = nil
                lastUsageAt = nil
                latestSpeed = nil
                hasModernUsageInTurn = false
                measuredOutput = 0
                measuredSeconds = 0
                return
            case "task_complete", "turn_completed", "turn_aborted":
                if let turnID, let endedID = payload["turn_id"] as? String, turnID != endedID { return }
                endedAt = time
                return
            case "item_completed":
                captureOutputStart(payload, completedAt: time)
                return
            case "thread_settings_applied":
                let settings = payload["thread_settings"] as? [String: Any]
                observeModel(settings?["model"], at: time)
                return
            case "model_rerouted":
                observeModel(payload["to_model"] ?? payload["toModel"] ?? payload["to"], at: time)
                return
            default:
                break
            }
        }

        let delta: Int
        if type == "token_usage_record" {
            if let owner = payload["thread_id"] as? String, owner != id { return }
            guard let usage = payload["usage"] as? [String: Any],
                  let output = usage["output_tokens"] as? Int, output >= 0 else { return }
            if let response = payload["response_id"] as? String, !seenResponses.insert(response).inserted { return }
            let total = payload["thread_token_usage"] as? [String: Any]
            cumulativeOutput = total?["output_tokens"] as? Int ?? cumulativeOutput
            if !isFork { conversationTokens = total?["total_tokens"] as? Int64 ?? conversationTokens }
            hasModernUsageInTurn = true
            delta = output
        } else if type == "event_msg", name == "token_count", let info = payload["info"] as? [String: Any] {
            guard let usage = info["total_token_usage"] as? [String: Any],
                  let total = usage["output_tokens"] as? Int, total >= 0 else { return }
            let last = (info["last_token_usage"] as? [String: Any])?["output_tokens"] as? Int
            let previous = cumulativeOutput
            cumulativeOutput = total
            // Modern records supply the batch directly. Their legacy copy
            // can arrive later and use a different cumulative counter.
            guard !hasModernUsageInTurn else { return }
            if !isFork { conversationTokens = usage["total_tokens"] as? Int64 ?? conversationTokens }
            let change = previous.map { total - $0 } ?? last ?? 0
            delta = min(change, last ?? change)
        } else {
            return
        }
        guard delta > 0, endedAt == nil else { return }

        started = true
        outputAt = max(outputAt ?? time, time)
        let boundary = requestBoundaryAt.flatMap { time.timeIntervalSince($0) >= 1 ? $0 : nil }
        let start = firstOutputAt ?? boundary ?? lastUsageAt ?? turnStartedAt
        if let start {
            let elapsed = time.timeIntervalSince(start)
            // When the first output is available, omit the time before it.
            // Older logs fall back to the observed interval between batches.
            // Ignore near-simultaneous legacy snapshots without output timing.
            if elapsed > 0, firstOutputAt != nil || elapsed >= 0.5 {
                let duration = max(0.5, elapsed)
                latestSpeed = SpeedSample(time: time, rate: Double(delta) / duration)
                measuredOutput += Double(delta)
                measuredSeconds += duration
            }
        }
        lastUsageAt = time
        requestBoundaryAt = nil
        firstOutputAt = nil
    }

    var averageRate: Double? { measuredSeconds > 0 ? measuredOutput / measuredSeconds : nil }

    private func observeModel(_ value: Any?, at time: Date) {
        guard let value = value as? String, !value.isEmpty,
              time >= (modelAt ?? .distantPast) else { return }
        model = value
        modelAt = time
    }

    func currentRate(at now: Date) -> Double? {
        guard let latestSpeed, latestSpeed.time <= now,
              now.timeIntervalSince(latestSpeed.time) <= freshSampleAge else { return nil }
        return latestSpeed.rate
    }

    private func captureOutputStart(_ payload: [String: Any], completedAt time: Date) {
        guard endedAt == nil,
              let item = payload["item"] as? [String: Any],
              let type = (item["type"] as? String)?.lowercased(),
              type == "reasoning" || type == "agentmessage" || type == "agent_message" else { return }
        outputAt = max(outputAt ?? time, time)
        guard let milliseconds = (payload["started_at_ms"] as? NSNumber)?.doubleValue else { return }
        let start = Date(timeIntervalSince1970: milliseconds / 1_000)
        guard start <= time, start >= (lastUsageAt ?? turnStartedAt ?? .distantPast) else { return }
        firstOutputAt = min(firstOutputAt ?? start, start)
    }

    func consume(_ data: Data, clock: RolloutClock) {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            if !skippingLine {
                if pending.count + end - start <= maxLineSize {
                    pending.append(contentsOf: data[start..<end])
                } else {
                    pending.removeAll(keepingCapacity: true)
                    skippingLine = true
                }
            }
            guard let newline else { break }
            if !skippingLine { apply(pending, clock: clock) }
            pending.removeAll(keepingCapacity: true)
            skippingLine = false
            start = data.index(after: newline)
        }
    }
}

private final class RolloutClock {
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()

    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parse(_ timestamp: String) -> Date? {
        fractional.date(from: timestamp) ?? whole.date(from: timestamp)
    }
}

private final class ThreadDirectory {
    private let databaseURL: URL
    private var database: OpaquePointer?
    private var titles: [String: String] = [:]
    private var parents: [String: String] = [:]
    private var models: [String: String] = [:]
    private var workspacePaths: [String: String] = [:]
    private var projectRoots: [String] = []
    private let workspaces = WorkspacePathResolver()
    private var expiresAt = Date.distantPast

    init(home: URL) {
        databaseURL = home.appendingPathComponent("state_5.sqlite")
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func refresh(at now: Date) {
        guard now >= expiresAt else { return }
        expiresAt = now.addingTimeInterval(8)
        titles.removeAll(keepingCapacity: true)
        parents.removeAll(keepingCapacity: true)
        models.removeAll(keepingCapacity: true)
        workspacePaths.removeAll(keepingCapacity: true)
        projectRoots = readAll("SELECT path FROM project_roots")
    }

    func title(for id: String) -> String {
        if let title = titles[id] { return title }
        let title = read("SELECT COALESCE(NULLIF(name, ''), title) FROM threads WHERE id = ?", id)
            ?? read("SELECT title FROM threads WHERE id = ?", id)
            ?? ""
        let displayTitle = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let result = displayTitle.isEmpty ? "对话 · \(id.suffix(6))" : String(displayTitle.prefix(140))
        titles[id] = result
        return result
    }

    func parent(of id: String) -> String? {
        if let parent = parents[id] { return parent.isEmpty ? nil : parent }
        let parent = read("SELECT parent_thread_id FROM thread_spawn_edges WHERE child_thread_id = ?", id)
        parents[id] = parent ?? ""
        return parent
    }

    func model(for id: String) -> String? {
        if let model = models[id] { return model.isEmpty ? nil : model }
        let model = read("SELECT model FROM threads WHERE id = ?", id) ?? ""
        models[id] = model
        return model.isEmpty ? nil : model
    }

    func project(for id: String, metadataPath: String?) -> String {
        if let path = workspacePaths[id] { return path }
        let assignedRoot = read("""
            SELECT r.path FROM threads t JOIN project_roots r ON r.project_id = t.project_id
            WHERE t.id = ? ORDER BY r.position LIMIT 1
            """, id)
        let path = assignedRoot ?? metadataPath ?? read("SELECT cwd FROM threads WHERE id = ?", id) ?? ""
        let matchingRoot = projectRoots
            .filter { path == $0 || path.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
        let project = workspaces.project(for: matchingRoot ?? path)
        workspacePaths[id] = project
        return project
    }

    private func connection() -> OpaquePointer? {
        if database == nil {
            var connection: OpaquePointer?
            let result = sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil)
            guard result == SQLITE_OK else {
                if let connection { sqlite3_close(connection) }
                return nil
            }
            database = connection
        }
        return database
    }

    private func readAll(_ sql: String) -> [String] {
        guard let database = connection() else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { paths.append(String(cString: text)) }
        }
        return paths
    }

    private func read(_ sql: String, _ id: String) -> String? {
        guard let database = connection() else { return nil }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        return id.withCString { bytes in
            sqlite3_bind_text(statement, 1, bytes, -1, nil)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let string = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: string)
        }
    }
}

final class CodexMeter {
    private struct Conversation {
        var latestActivity: Date
        var active = false
        var currentRate: Double?
        var lastSpeed: SpeedSample?
        var workspacePath: String?
        var latestOutput: Date?
        var recentRunner: Rollout?
    }

    private let sessionsURL: URL
    private let threads: ThreadDirectory
    private let clock = RolloutClock()
    private let fileManager = FileManager.default
    private var rollouts: [URL: Rollout] = [:]
    private var nextScan = Date.distantPast
    private var sourceAvailable = false

    static var codexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    init(home: URL = CodexMeter.codexHome) {
        sessionsURL = home.appendingPathComponent("sessions", isDirectory: true)
        threads = ThreadDirectory(home: home)
    }

    // Call from a single background queue.
    func sample(now: Date = Date()) -> MeterSnapshot {
        if now >= nextScan {
            nextScan = now.addingTimeInterval(1.5)
            discover(now: now)
        }
        guard sourceAvailable else { return MeterSnapshot(rows: [], sourceAvailable: false) }
        threads.refresh(at: now)

        for (url, rollout) in rollouts {
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let modified = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) <= activeTimeout else {
                rollouts.removeValue(forKey: url)
                continue
            }
            let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
            var current = rollout
            if rollout.offset > size || (rollout.inode != nil && inode != rollout.inode) {
                current = Rollout(url: url, modified: modified)
                rollouts[url] = current
            }
            current.inode = inode
            current.lastModified = modified
            if size > current.offset {
                read(current, size: size)
            }
        }

        let latestRollouts = rollouts.values.reduce(into: [String: Rollout]()) { newest, rollout in
            if newest[rollout.id].map({ $0.lastModified >= rollout.lastModified }) != true {
                newest[rollout.id] = rollout
            }
        }
        let parentMap = latestRollouts.values.reduce(into: [String: String]()) { parents, rollout in
            if let parent = rollout.parentID { parents[rollout.id] = parent }
        }
        var conversations: [String: Conversation] = [:]
        for rollout in latestRollouts.values {
            if let ended = rollout.endedAt {
                guard now.timeIntervalSince(ended) <= finishedVisibility else { continue }
            } else if !rollout.started {
                continue
            }

            let id = rootID(for: rollout.id, parents: parentMap)
            let rootEnd = latestRollouts[id]?.endedAt
            if let rootEnd, now.timeIntervalSince(rootEnd) > finishedVisibility { continue }
            let activity = rollout.endedAt ?? rollout.lastModified
            var conversation = conversations[id] ?? Conversation(latestActivity: activity)
            conversation.workspacePath = latestRollouts[id]?.workspacePath ?? conversation.workspacePath ?? rollout.workspacePath
            conversation.latestActivity = max(conversation.latestActivity, activity)
            if let output = rollout.outputAt, output <= now,
               output > (conversation.latestOutput ?? .distantPast) {
                conversation.latestOutput = output
                conversation.recentRunner = rollout
            }
            if rootEnd == nil, rollout.endedAt == nil {
                conversation.active = true
                if let rate = rollout.currentRate(at: now) {
                    conversation.currentRate = (conversation.currentRate ?? 0) + rate
                }
            }
            if let speed = rollout.latestSpeed, speed.time <= now,
               conversation.lastSpeed.map({ $0.time >= speed.time }) != true {
                conversation.lastSpeed = speed
            }
            conversations[id] = conversation
        }

        let rows = conversations.sorted { left, right in
            if left.value.active != right.value.active { return left.value.active }
            if left.value.latestActivity != right.value.latestActivity {
                return left.value.latestActivity > right.value.latestActivity
            }
            return left.key < right.key
        }.map { id, conversation in
            let state: MeterState = conversation.active
                ? (conversation.currentRate == nil ? .waiting : .generating)
                : .finished
            let root = latestRollouts[id]
            let lastRate = root?.latestSpeed?.rate ?? conversation.lastSpeed?.rate
            let rate = conversation.active ? conversation.currentRate : lastRate
            return MeterRow(
                id: id, title: threads.title(for: id), rate: rate, state: state,
                project: threads.project(for: id, metadataPath: conversation.workspacePath),
                model: root?.model ?? threads.model(for: id) ?? conversation.recentRunner?.model,
                outputAt: root?.outputAt.flatMap { $0 <= now ? $0 : nil } ?? conversation.latestOutput,
                averageRate: root?.averageRate ?? conversation.recentRunner?.averageRate,
                totalTokens: root?.conversationTokens
            )
        }
        return MeterSnapshot(rows: rows, sourceAvailable: true)
    }

    private func rootID(for id: String, parents: [String: String]) -> String {
        var root = id
        var seen: Set<String> = [root]
        while let parent = parents[root] ?? threads.parent(of: root), seen.insert(parent).inserted {
            root = parent
        }
        return root
    }

    private func discover(now: Date) {
        sourceAvailable = fileManager.isReadableFile(atPath: sessionsURL.path)
        guard sourceAvailable else {
            rollouts.removeAll()
            return
        }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = fileManager.enumerator(at: sessionsURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            sourceAvailable = false
            return
        }
        for case let url as URL in files where url.pathExtension == "jsonl" && rollouts[url] == nil {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) <= activeTimeout else { continue }
            rollouts[url] = Rollout(url: url, modified: modified)
        }
    }

    private func read(_ rollout: Rollout, size: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: rollout.url) else { return }
        defer { try? handle.close() }
        do {
            if rollout.offset == 0, size > UInt64(tailSize) {
                let beginning = try handle.read(upToCount: maxLineSize) ?? Data()
                if let newline = beginning.firstIndex(of: 10) {
                    rollout.apply(Data(beginning.prefix(upTo: newline)), clock: clock)
                }
                rollout.offset = size - UInt64(tailSize)
                rollout.skippingLine = true
            }
            try handle.seek(toOffset: rollout.offset)
            while rollout.offset < size {
                let count = Int(min(64 * 1024, size - rollout.offset))
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                rollout.consume(chunk, clock: clock)
                rollout.offset += UInt64(chunk.count)
            }
        } catch {
            // A writer may rotate or truncate the rollout between polls.
        }
    }
}
