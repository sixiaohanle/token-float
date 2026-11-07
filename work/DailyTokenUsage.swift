import Foundation

struct DailyTokenSnapshot: Equatable {
    var total: Int64
    var complete: Bool
}

private struct UsageTurn: Hashable {
    var thread: String
    var turn: String
}

private struct UsageKey: Hashable {
    var thread: String
    var event: String
}

private struct RecordedUsage {
    var turn: UsageTurn
    var tokens: Int64
    var time: Date

    func merged(with other: RecordedUsage) -> RecordedUsage {
        RecordedUsage(turn: turn, tokens: max(tokens, other.tokens), time: min(time, other.time))
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
    var hasMetadata = false
    var cumulative: Int64?
    var pending = Data()
    var droppingLine = false
    var modernTurns: Set<UsageTurn> = []
    var responses: [UsageKey: RecordedUsage] = [:]
    var legacy: [UsageKey: RecordedUsage] = [:]

    init(url: URL) {
        compressed = url.pathExtension == "zst"
        let rollout = compressed ? url.deletingPathExtension() : url
        thread = String(rollout.deletingPathExtension().lastPathComponent.suffix(36))
    }

    func consume(_ chunk: Data, day: DateInterval, clock: UsageClock) {
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let newline = chunk[start...].firstIndex(of: 10)
            let end = newline ?? chunk.endIndex
            if !droppingLine {
                if pending.isEmpty, let newline, end - start <= dailyLineLimit {
                    apply(chunk[start..<newline], day: day, clock: clock)
                } else if pending.count + end - start <= dailyLineLimit {
                    pending.append(contentsOf: chunk[start..<end])
                    if newline != nil { apply(pending, day: day, clock: clock) }
                } else {
                    droppingLine = true
                }
            }
            guard let newline else { break }
            pending.removeAll(keepingCapacity: true)
            droppingLine = false
            start = chunk.index(after: newline)
        }
    }

    private func apply(_ line: Data, day: DateInterval, clock: UsageClock) {
        let header = line.prefix(384)
        guard dailyHeaders.contains(where: { header.range(of: $0) != nil }),
              let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = event["type"] as? String,
              let payload = event["payload"] as? [String: Any] else { return }

        if type == "session_meta" {
            guard !hasMetadata else { return }
            hasMetadata = true
            thread = payload["id"] as? String ?? thread
            sourceOrdinal = payload["subagent_history_start_ordinal"] as? Int
            return
        }
        let ordinal = event["ordinal"] as? Int
        if let sourceOrdinal, let ordinal, ordinal < sourceOrdinal { return }
        let name = payload["type"] as? String
        if type == "event_msg", name == "task_started" || name == "turn_started" {
            turn = payload["turn_id"] as? String ?? turn
            return
        }
        guard let stamp = event["timestamp"] as? String, let time = clock.parse(stamp), time < day.end else { return }

        if type == "token_usage_record" {
            if let owner = payload["thread_id"] as? String, owner != thread { return }
            guard let tokens = Self.total(payload["usage"]) else { return }
            let usageTurn = UsageTurn(thread: thread, turn: payload["turn_id"] as? String ?? turn)
            modernTurns.insert(usageTurn)
            modernTurns.insert(UsageTurn(thread: thread, turn: turn))
            let id = payload["response_id"] as? String ?? "\(stamp):\(ordinal ?? 0)"
            let key = UsageKey(thread: thread, event: id)
            let usage = RecordedUsage(turn: usageTurn, tokens: tokens, time: time)
            responses[key] = responses[key]?.merged(with: usage) ?? usage
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
        guard delta > 0, !modernTurns.contains(usageTurn) else { return }

        // Older logs can be copied verbatim when a session is archived.
        let key = UsageKey(thread: thread, event: "\(stamp):\(total)")
        legacy[key] = RecordedUsage(turn: usageTurn, tokens: delta, time: time)
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
    private var totals: [String: Int64] = [:]

    init(home: URL = CodexMeter.codexHome) {
        self.home = home
    }

    func conversationTotals() -> [String: Int64] { totals }

    // Read on a separate queue so a cold scan does not delay the speed display.
    func sample(now: Date = Date()) -> DailyTokenSnapshot {
        guard let today = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: now) else {
            return DailyTokenSnapshot(total: 0, complete: false)
        }
        if day != today {
            day = today
            files.removeAll()
        }
        let cutoff = min(today.start, now.addingTimeInterval(-20 * 60))

        var complete = true
        for directory in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(directory, isDirectory: true)
            if !fileManager.fileExists(atPath: root.path), directory == "archived_sessions" { continue }
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
                var file = files[url] ?? DailyUsageFile(url: url)
                let identity = properties.fileResourceIdentifier as? NSObject
                let replaced = file.identity != nil && identity != file.identity
                if replaced || (file.compressed && (file.modified != modified || !file.readable)) || file.offset > UInt64(size) {
                    file = DailyUsageFile(url: url)
                }
                files[url] = file
                file.identity = identity
                if file.compressed {
                    if !file.finished { file.readable = readCompressed(url, into: file, day: today) }
                } else if file.offset < UInt64(size) {
                    file.readable = readPlain(url, through: UInt64(size), into: file, day: today)
                }
                file.modified = modified
                complete = complete && file.readable
            }
        }

        var modernTurns: Set<UsageTurn> = []
        var responses: [UsageKey: RecordedUsage] = [:]
        var legacy: [UsageKey: RecordedUsage] = [:]
        for file in files.values {
            modernTurns.formUnion(file.modernTurns)
            responses.merge(file.responses) { $0.merged(with: $1) }
            legacy.merge(file.legacy) { $0.merged(with: $1) }
        }

        var total: Int64 = 0
        totals.removeAll(keepingCapacity: true)
        func count(_ usage: RecordedUsage, for key: UsageKey) {
            totals[key.thread] = Self.adding(totals[key.thread] ?? 0, usage.tokens)
            if usage.time >= today.start { total = Self.adding(total, usage.tokens) }
        }
        for (key, usage) in responses { count(usage, for: key) }
        for (key, usage) in legacy where !modernTurns.contains(usage.turn) {
            count(usage, for: key)
        }
        return DailyTokenSnapshot(total: total, complete: complete)
    }

    private static func adding(_ total: Int64, _ delta: Int64) -> Int64 {
        let (sum, overflow) = total.addingReportingOverflow(delta)
        return overflow ? Int64.max : sum
    }

    private func readPlain(_ url: URL, through size: UInt64, into file: DailyUsageFile, day: DateInterval) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: file.offset)
            while file.offset < size {
                let count = Int(min(size - file.offset, 512 * 1024))
                guard let data = try handle.read(upToCount: count), !data.isEmpty else { return false }
                file.consume(data, day: day, clock: clock)
                file.offset += UInt64(data.count)
            }
            return true
        } catch {
            return false
        }
    }

    private func readCompressed(_ url: URL, into file: DailyUsageFile, day: DateInterval) -> Bool {
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
            while let data = try output.fileHandleForReading.read(upToCount: 512 * 1024), !data.isEmpty {
                file.consume(data, day: day, clock: clock)
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
