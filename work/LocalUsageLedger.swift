import CryptoKit
import Foundation
import SQLite3

struct LedgerDayTotal: Equatable {
    var beforeMigration: Int64 = 0
    var afterMigration: Int64 = 0
    var hasEvents = false
    var revision: UInt64 = 0

    func includingLegacy(_ legacy: Int64) -> Int64 {
        addingUsage(max(legacy, beforeMigration), afterMigration)
    }
}

func addingUsage(_ left: Int64, _ right: Int64) -> Int64 {
    let (total, overflow) = left.addingReportingOverflow(right)
    return overflow ? Int64.max : total
}

enum UsageDayKey {
    static func make(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// The database stores daily sums and opaque bookkeeping keys. Conversation text,
// titles, model names and paths stay out of it.
final class LocalUsageLedger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.xiaohan.codex-token-float.usage-ledger", qos: .utility)
    private let db: UsageDatabase?
    private let migrationTime: Double
    private var revision: UInt64 = 0

    init(url: URL? = nil, now: Date = Date()) {
        let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Token Float", isDirectory: true)
            .appendingPathComponent("usage.sqlite3")
        do {
            let target = url ?? defaultURL
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let database = try UsageDatabase(url: target)
            try database.exec(Self.schema)
            let migration = try database.statement("INSERT OR IGNORE INTO metadata VALUES ('migration', ?)")
            try migration.bind(now.timeIntervalSince1970, at: 1)
            try migration.run()
            let timestamp = try database.statement("SELECT value FROM metadata WHERE key = 'migration'")
            guard try timestamp.next() else { throw UsageDatabaseError.operationFailed }
            migrationTime = timestamp.double(at: 0)
            db = database
        } catch {
            migrationTime = now.timeIntervalSince1970
            db = nil
        }
    }

    var isAvailable: Bool { db != nil }

    static func sourceKey(provider: MeterProvider, home: URL) -> String {
        sourceKey(legacyKey: provider.rawValue + ":" + home.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    static func sourceKey(legacyKey: String) -> String {
        fingerprint(legacyKey).base64EncodedString()
    }

    private static func fingerprint(_ value: String) -> Data {
        Data(SHA256.hash(data: Data(value.utf8)))
    }

    func savedTotals() -> [String: [String: LedgerDayTotal]] {
        queue.sync {
            guard let db else { return [:] }
            do {
                let rows = try db.statement("SELECT source, day, before, after FROM totals")
                var results: [String: [String: LedgerDayTotal]] = [:]
                while try rows.next() {
                    results[rows.string(at: 0), default: [:]][rows.string(at: 1)] = LedgerDayTotal(
                        beforeMigration: rows.integer(at: 2), afterMigration: rows.integer(at: 3), hasEvents: true
                    )
                }
                return results
            } catch {
                return [:]
            }
        }
    }

    func needsImport(_ file: HistoryLogRevision, source: String) -> Bool {
        queue.sync {
            guard let db else { return false }
            do {
                let row = try db.statement("SELECT modified, size, identity FROM imported_files WHERE source = ? AND id = ?")
                try row.bind(source, at: 1)
                try row.bind(Self.fingerprint(file.url.standardizedFileURL.path), at: 2)
                guard try row.next() else { return true }
                return row.double(at: 0) != file.modified.timeIntervalSince1970
                    || row.integer(at: 1) != Int64(clamping: file.size)
                    || row.string(at: 2) != file.identity
            } catch {
                return true
            }
        }
    }

    func record(
        _ events: [HistoryUsageEvent], source: String, file: HistoryLogRevision? = nil
    ) -> [String: LedgerDayTotal]? {
        queue.sync {
            guard let db else { return nil }
            if events.isEmpty && file == nil { return [:] }
            do {
                try db.exec("BEGIN IMMEDIATE; DELETE FROM changed_days;")
                let changed = try write(events, source: source, file: file, in: db)
                try db.exec("COMMIT")
                revision += 1
                return changed.mapValues { total in
                    var updated = total
                    updated.revision = revision
                    return updated
                }
            } catch {
                try? db.exec("ROLLBACK")
                return nil
            }
        }
    }

    private func write(
        _ events: [HistoryUsageEvent], source: String, file: HistoryLogRevision?, in db: UsageDatabase
    ) throws -> [String: LedgerDayTotal] {
        if !events.isEmpty {
            let eventRow = try db.statement("""
                INSERT INTO events VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, id) DO UPDATE SET
                    stamp = min(events.stamp, excluded.stamp),
                    day = CASE WHEN excluded.stamp < events.stamp THEN excluded.day ELSE events.day END,
                    tokens = max(events.tokens, excluded.tokens),
                    legacy = coalesce(events.legacy, excluded.legacy)
                WHERE excluded.tokens > events.tokens OR excluded.stamp < events.stamp
                """)
            let turnRow = try db.statement("INSERT OR IGNORE INTO modern_turns VALUES (?, ?)")
            for event in events where event.tokens >= 0 {
                try eventRow.bind(source, at: 1)
                try eventRow.bind(Self.fingerprint(event.id), at: 2)
                try eventRow.bind(event.time.timeIntervalSince1970, at: 3)
                try eventRow.bind(UsageDayKey.make(for: event.time), at: 4)
                try eventRow.bind(event.tokens, at: 5)
                try eventRow.bind(event.legacyGroup.map(Self.fingerprint), at: 6)
                try eventRow.run()
                for turn in event.supersedesLegacy {
                    try turnRow.bind(source, at: 1)
                    try turnRow.bind(Self.fingerprint(turn), at: 2)
                    try turnRow.run()
                }
            }
        }

        if let file {
            let checkpoint = try db.statement("INSERT OR REPLACE INTO imported_files VALUES (?, ?, ?, ?, ?)")
            try checkpoint.bind(source, at: 1)
            try checkpoint.bind(Self.fingerprint(file.url.standardizedFileURL.path), at: 2)
            try checkpoint.bind(file.modified.timeIntervalSince1970, at: 3)
            try checkpoint.bind(Int64(clamping: file.size), at: 4)
            try checkpoint.bind(file.identity, at: 5)
            try checkpoint.run()
        }

        let changedDays = try db.statement("SELECT day FROM changed_days")
        let counts = try db.statement("""
            SELECT stamp, tokens FROM events
            WHERE source = ? AND day = ?
                AND (legacy IS NULL OR NOT EXISTS (
                    SELECT 1 FROM modern_turns WHERE modern_turns.source = events.source AND modern_turns.id = events.legacy
                ))
            """)
        let totalRow = try db.statement("INSERT OR REPLACE INTO totals VALUES (?, ?, ?, ?)")
        let removeRow = try db.statement("DELETE FROM totals WHERE source = ? AND day = ?")
        var result: [String: LedgerDayTotal] = [:]
        while try changedDays.next() {
            let day = changedDays.string(at: 0)
            try counts.bind(source, at: 1)
            try counts.bind(day, at: 2)
            var total = LedgerDayTotal()
            while try counts.next() {
                total.hasEvents = true
                if counts.double(at: 0) <= migrationTime {
                    total.beforeMigration = addingUsage(total.beforeMigration, counts.integer(at: 1))
                } else {
                    total.afterMigration = addingUsage(total.afterMigration, counts.integer(at: 1))
                }
            }
            counts.reset()
            if total.hasEvents {
                try totalRow.bind(source, at: 1)
                try totalRow.bind(day, at: 2)
                try totalRow.bind(total.beforeMigration, at: 3)
                try totalRow.bind(total.afterMigration, at: 4)
                try totalRow.run()
            } else {
                try removeRow.bind(source, at: 1)
                try removeRow.bind(day, at: 2)
                try removeRow.run()
            }
            result[day] = total
        }
        return result
    }

    private static let schema = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = FULL;
        CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS events (
            source TEXT NOT NULL, id BLOB NOT NULL, stamp REAL NOT NULL, day TEXT NOT NULL,
            tokens INTEGER NOT NULL, legacy BLOB, PRIMARY KEY (source, id)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS events_by_day ON events (source, day);
        CREATE INDEX IF NOT EXISTS events_by_legacy ON events (source, legacy) WHERE legacy IS NOT NULL;
        CREATE TABLE IF NOT EXISTS modern_turns (
            source TEXT NOT NULL, id BLOB NOT NULL, PRIMARY KEY (source, id)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS totals (
            source TEXT NOT NULL, day TEXT NOT NULL, before INTEGER NOT NULL, after INTEGER NOT NULL,
            PRIMARY KEY (source, day)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS imported_files (
            source TEXT NOT NULL, id BLOB NOT NULL, modified REAL NOT NULL,
            size INTEGER NOT NULL, identity TEXT NOT NULL, PRIMARY KEY (source, id)
        ) WITHOUT ROWID;
        CREATE TEMP TABLE changed_days (day TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TEMP TRIGGER event_added AFTER INSERT ON main.events BEGIN
            INSERT OR IGNORE INTO changed_days VALUES (NEW.day);
        END;
        CREATE TEMP TRIGGER event_changed AFTER UPDATE ON main.events BEGIN
            INSERT INTO changed_days VALUES (OLD.day) ON CONFLICT(day) DO NOTHING;
            INSERT INTO changed_days VALUES (NEW.day) ON CONFLICT(day) DO NOTHING;
        END;
        CREATE TEMP TRIGGER modern_turn_added AFTER INSERT ON main.modern_turns BEGIN
            INSERT OR IGNORE INTO changed_days SELECT day FROM events WHERE source = NEW.source AND legacy = NEW.id;
        END;
        """
}

private enum UsageDatabaseError: Error { case operationFailed }

private final class UsageDatabase {
    let connection: OpaquePointer

    init(url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let connection else {
            sqlite3_close(connection)
            throw UsageDatabaseError.operationFailed
        }
        self.connection = connection
        sqlite3_busy_timeout(connection, 5_000)
    }

    deinit { sqlite3_close(connection) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw UsageDatabaseError.operationFailed }
    }

    func statement(_ sql: String) throws -> UsageStatement {
        try UsageStatement(connection: connection, sql: sql)
    }
}

private final class UsageStatement {
    private let pointer: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(connection: OpaquePointer, sql: String) throws {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else {
            throw UsageDatabaseError.operationFailed
        }
        self.pointer = pointer
    }

    deinit { sqlite3_finalize(pointer) }

    func bind(_ value: String, at index: Int32) throws {
        try check(sqlite3_bind_text(pointer, index, value, -1, Self.transient))
    }

    func bind(_ value: Data?, at index: Int32) throws {
        let status = value.map { bytes in
            bytes.withUnsafeBytes { sqlite3_bind_blob(pointer, index, $0.baseAddress, Int32($0.count), Self.transient) }
        } ?? sqlite3_bind_null(pointer, index)
        try check(status)
    }

    func bind(_ value: Double, at index: Int32) throws { try check(sqlite3_bind_double(pointer, index, value)) }
    func bind(_ value: Int64, at index: Int32) throws { try check(sqlite3_bind_int64(pointer, index, value)) }
    func double(at index: Int32) -> Double { sqlite3_column_double(pointer, index) }
    func integer(at index: Int32) -> Int64 { sqlite3_column_int64(pointer, index) }
    func string(at index: Int32) -> String { String(cString: sqlite3_column_text(pointer, index)) }

    func next() throws -> Bool {
        let status = sqlite3_step(pointer)
        if status == SQLITE_ROW { return true }
        guard status == SQLITE_DONE else { throw UsageDatabaseError.operationFailed }
        return false
    }

    func run() throws {
        guard sqlite3_step(pointer) == SQLITE_DONE else { throw UsageDatabaseError.operationFailed }
        reset()
    }

    func reset() { sqlite3_reset(pointer) }

    private func check(_ status: Int32) throws {
        guard status == SQLITE_OK else { throw UsageDatabaseError.operationFailed }
    }
}
