import Foundation
import SQLite3

struct AntigravitySample {
    let outputTokens: Int
    let startedAt: Date
    let endedAt: Date
    let generationSeconds: Double
    let model: String?
}

struct AntigravityUsageStep {
    let stepIndex: Int64
    let time: Date
    let tokens: Int64
}

enum AntigravitySampleReader {
    // Antigravity's CortexStepMetadata is small. Its separate step_payload
    // and gen_metadata blobs may contain megabytes of conversation content.
    static func latest(in db: URL) -> AntigravitySample? {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard sqlite3_open_v2(db.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        let query = """
            SELECT metadata FROM steps
            WHERE idx > (SELECT MAX(idx) - 256 FROM steps)
              AND step_type = 15 AND status = 3
              AND length(metadata) BETWEEN 1 AND 65536
            ORDER BY idx DESC LIMIT 16
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return nil }

        var latest: AntigravitySample?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let buffer = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            let bytes = Data(bytes: buffer, count: count)
            guard let sample = try? decode(bytes), latest.map({ sample.endedAt > $0.endedAt }) ?? true else { continue }
            latest = sample
        }
        return latest
    }

    static func usage(in db: URL, shouldCancel: () -> Bool = { false }) -> [AntigravityUsageStep]? {
        guard !shouldCancel() else { return nil }
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard sqlite3_open_v2(db.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }

        // Emit an inexpensive NULL for unrelated steps so cancellation is
        // checked even in a long run of tool calls. Types 15 and 23 are
        // model replies and context checkpoints, each with its own usage.
        let query = """
            SELECT idx, CASE WHEN step_type IN (15, 23) AND status IN (3, 5, 6, 7, 12)
                AND length(metadata) BETWEEN 1 AND 65536 THEN metadata END
            FROM steps WHERE idx >= 0 ORDER BY idx
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return nil }

        var events: [AntigravityUsageStep] = []
        while !shouldCancel() {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return events
            case SQLITE_ROW:
                guard let buffer = sqlite3_column_blob(statement, 1) else { continue }
                let bytes = Data(bytes: buffer, count: Int(sqlite3_column_bytes(statement, 1)))
                if let event = try? decodeUsage(bytes, index: sqlite3_column_int64(statement, 0)) {
                    events.append(event)
                }
            default: return nil
            }
        }
        return nil
    }

    private static func decodeUsage(_ metadata: Data, index: Int64) throws -> AntigravityUsageStep? {
        let fields = try ProtoFields(metadata, keeping: [1, 7, 8, 9])
        guard let usage = fields.messages[9],
              let time = try timestamp(fields.messages[7]) ?? timestamp(fields.messages[8]) ?? timestamp(fields.messages[1])
        else { return nil }
        // ModelUsageStats separates ordinary input (2), output (3), cache
        // writes (4) and cache reads (5). Thinking is already in output.
        let counts = try ProtoFields(usage, keeping: [2, 3, 4, 5])
        var total: Int64 = 0
        for raw in counts.numbers.values {
            guard let tokens = Int64(exactly: raw), tokens <= Int64.max - total else { return nil }
            total += tokens
        }
        guard total > 0 else { return nil }
        return AntigravityUsageStep(stepIndex: index, time: time, tokens: total)
    }

    private static func decode(_ metadata: Data) throws -> AntigravitySample? {
        // 6 = viewable_at (first output), 7 = finished_generating_at.
        // Their difference matches ChatModelMetadata.streaming_duration.
        let fields = try ProtoFields(metadata, keeping: [6, 7, 9, 24])
        guard let start = try timestamp(fields.messages[6]), let end = try timestamp(fields.messages[7]),
              end > start, let usage = fields.messages[9] else { return nil }
        let counts = try ProtoFields(usage, keeping: [3])
        guard let raw = counts.numbers[3], let outputTokens = Int(exactly: raw), outputTokens > 0 else { return nil }

        var model: String?
        if let data = fields.messages[24], let info = try? ProtoFields(data, keeping: [8, 12, 20]) {
            for field in [20, 8, 12] {
                guard let value = info.messages[field], !value.isEmpty, value.count <= 256,
                      let name = String(data: value, encoding: .utf8),
                      name.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
                model = name
                break
            }
        }
        return AntigravitySample(outputTokens: outputTokens, startedAt: start, endedAt: end,
                                 generationSeconds: end.timeIntervalSince(start), model: model)
    }

    private static func timestamp(_ bytes: Data?) throws -> Date? {
        guard let bytes else { return nil }
        let value = try ProtoFields(bytes, keeping: [1, 2])
        let nanos = value.numbers[2] ?? 0
        guard let seconds = value.numbers[1], seconds > 0, seconds <= 253_402_300_799,
              nanos < 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }

    // Read only named fields from the protobuf wire format. Ignore additive
    // schema changes and skip an invalid record if any length exceeds its blob.
    private struct ProtoFields {
        var numbers: [Int: UInt64] = [:]
        var messages: [Int: Data] = [:]
        private enum Failure: Error { case invalid }

        init(_ bytes: Data, keeping fields: Set<Int>) throws {
            var cursor = bytes.startIndex
            while cursor < bytes.endIndex {
                let tag = try Self.varint(bytes, &cursor)
                let field = Int(tag >> 3)
                guard field > 0, field <= 0x1fffffff else { throw Failure.invalid }
                let length: Int
                switch tag & 7 {
                case 0:
                    let n = try Self.varint(bytes, &cursor)
                    if fields.contains(field) { numbers[field] = n }
                    continue
                case 1: length = 8
                case 2:
                    let n = try Self.varint(bytes, &cursor)
                    guard let size = Int(exactly: n) else { throw Failure.invalid }
                    length = size
                case 5: length = 4
                default: throw Failure.invalid
                }
                guard length <= bytes.endIndex - cursor else { throw Failure.invalid }
                let end = cursor + length
                if tag & 7 == 2, fields.contains(field) { messages[field] = bytes[cursor..<end] }
                cursor = end
            }
        }

        private static func varint(_ bytes: Data, _ cursor: inout Int) throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard cursor < bytes.endIndex else { throw Failure.invalid }
                let byte = bytes[cursor]
                cursor += 1
                guard shift < 63 || byte <= 1 else { throw Failure.invalid }
                value |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return value }
            }
            throw Failure.invalid
        }
    }
}
