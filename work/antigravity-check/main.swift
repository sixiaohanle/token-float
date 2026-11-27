import Foundation
import SQLite3

// Minimal CortexStepMetadata fixtures let the check run without a Google account.
func varint(_ value: UInt64) -> Data {
    var number = value
    var bytes = Data()
    while number >= 128 {
        bytes.append(UInt8(number & 127) | 128)
        number >>= 7
    }
    bytes.append(UInt8(number))
    return bytes
}

func integer(_ field: UInt64, _ value: UInt64) -> Data {
    varint(field << 3) + varint(value)
}

func message(_ field: UInt64, _ bytes: Data) -> Data {
    varint(field << 3 | 2) + varint(UInt64(bytes.count)) + bytes
}

func metadata(second: UInt64, output: UInt64) -> Data {
    let start = integer(1, second - 1) + integer(2, 500_000_000)
    let end = integer(1, second) + integer(2, 250_000_000)
    let usage = integer(2, 90) + integer(3, output) + integer(4, 20) + integer(5, 300)
    return message(6, start) + message(7, end) + message(9, usage)
}

final class Conversation {
    let url: URL
    private let db: OpaquePointer

    init(root: URL, product: String, name: String) throws {
        let directory = root.appendingPathComponent(product + "/conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(name + ".db")
        var connection: OpaquePointer?
        precondition(sqlite3_open(url.path, &connection) == SQLITE_OK)
        db = connection!
        precondition(sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK)
        precondition(sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0", nil, nil, nil) == SQLITE_OK)
        let createTable = "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER, metadata BLOB)"
        precondition(sqlite3_exec(db, createTable, nil, nil, nil) == SQLITE_OK)
    }

    deinit { sqlite3_close(db) }

    func append(_ bytes: Data, type: Int = 15, status: Int = 3) {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let sql = "INSERT INTO steps(step_type,status,metadata) VALUES(\(type),\(status),x'\(hex)')"
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}

func check() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let second = UInt64(Date().timeIntervalSince1970) - 1
    let now = Date(timeIntervalSince1970: Double(second) + 1)
    let id = UUID().uuidString
    let meter = AntigravityMeter(home: root)
    precondition(!meter.sample(now: now.addingTimeInterval(-10)).sourceAvailable)

    let app = try Conversation(root: root, product: "antigravity", name: id)
    let ide = try Conversation(root: root, product: "antigravity-ide", name: id)
    app.append(metadata(second: second, output: 120))
    ide.append(metadata(second: second - 1, output: 150))
    app.append(Data([0x32, 0x80])) // Incomplete protobuf
    app.append(message(9, integer(3, 0)))
    app.append(metadata(second: second, output: 9999), type: 1)
    app.append(metadata(second: second, output: 9999), status: 1)
    let sample = AntigravitySampleReader.latest(in: app.url)!
    precondition(sample.outputTokens == 120 && sample.generationSeconds == 0.75)
    let checkpoint = message(8, integer(1, second)) + message(9, integer(2, 100))
    app.append(checkpoint, type: 23, status: 5)
    precondition(AntigravitySampleReader.usage(in: app.url)?.map(\.tokens) == [530, 100])
    precondition(AntigravitySampleReader.usage(in: app.url, shouldCancel: { true }) == nil)
    let ledger = LocalUsageLedger(url: root.appendingPathComponent("ledger.sqlite3"), now: now)
    let source = LocalUsageLedger.sourceKey(provider: .antigravity, home: root)
    let usage = AntigravityUsage(home: root)
    let dayKey = UsageDayKey.make(for: sample.endedAt)
    var readCount = 0
    func importUsage() {
        precondition(usage.scan(
            shouldRead: { ledger.needsImport($0, source: source) },
            shouldCancel: { false },
            receive: { revision, events in
                precondition(ledger.record(events, source: source, file: revision) != nil)
                readCount += 1
            }
        ))
    }
    importUsage()
    precondition(readCount == 2)
    let initialTotal = ledger.savedTotals()[source]!.values.reduce(0) { $0 + $1.includingLegacy(0) }
    precondition(initialTotal == 660) // App and IDE both have the same first model step.
    importUsage()
    precondition(readCount == 2)
    var snapshot = meter.sample(now: now)
    precondition(snapshot.sourceAvailable && snapshot.rows.count == 1 && snapshot.rows[0].rate == 160)

    // The writer stays open. The updated response is visible through the WAL.
    let other = try Conversation(root: root, product: "antigravity-ide", name: UUID().uuidString)
    other.append(metadata(second: second + 2, output: 30))
    app.append(metadata(second: second + 2, output: 75))
    importUsage()
    precondition(readCount == 4)
    let updatedTotal = ledger.savedTotals()[source]!.values.reduce(0) { $0 + $1.includingLegacy(0) }
    precondition(updatedTotal == 1585)
    precondition(ledger.savedTotals()[source]?[dayKey]?.hasEvents == true)
    snapshot = meter.sample(now: now.addingTimeInterval(5))
    precondition(snapshot.rows.compactMap(\.rate).sorted() == [40, 100])
    let entry = ProviderMeter(provider: .antigravity, snapshot: snapshot)
    precondition(ProviderMeter.combinedRate([entry]) == 140)
    let expired = meter.sample(now: now.addingTimeInterval(30))
    precondition(expired.rows.allSatisfy { $0.rate == nil })
    precondition(meter.sample(now: now.addingTimeInterval(150)).rows.isEmpty)
    withExtendedLifetime((app, ide, other)) {}
}
try check()
print("PASS Antigravity timing, WAL, malformed records, App/IDE deduplication, ledger checkpoints, historical usage and expiry")
