import Darwin
import Foundation
import SQLite3

struct CodexArchiveCandidate {
    let threadID: String
    let tokens: Int64
    let startedAt: Date
    let endedAt: Date?
    let logPaths: [URL]
}

enum CodexArchiveRecovery {
    static func candidates(home: URL) -> [CodexArchiveCandidate] {
        readCandidates(home: home, allowBackendOnly: false) ?? []
    }

    static func backendCandidates(home: URL) -> [CodexArchiveCandidate]? {
        readCandidates(home: home, allowBackendOnly: true)
    }

    private static func readCandidates(home: URL, allowBackendOnly: Bool) -> [CodexArchiveCandidate]? {
        let home = home.standardizedFileURL
        let databaseURL = home.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 250)

        // These tagged exec clients could start or resume a thread. They had
        // no fork command. Other versions and sources need independent evidence.
        let verifiedOnly = allowBackendOnly ? "" : """
             AND t.history_mode = 'legacy'
              AND t.source = 'exec' AND t.thread_source = 'user'
              AND t.cli_version IN ('0.130.0-alpha.5', '0.131.0-alpha.9')
              AND t.originator = 'codex_exec'
              AND t.attached_thread_parent_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM thread_spawn_edges s WHERE s.child_thread_id = t.id)
            """
        let query = """
            SELECT t.id, t.rollout_path, t.tokens_used, t.created_at, t.created_at_ms,
                t.updated_at, t.updated_at_ms, t.archived_at
            FROM threads t
            WHERE t.archived = 1 AND t.tokens_used > 0\(verifiedOnly)
            ORDER BY t.id
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }

        var status = sqlite3_step(statement)
        if status == SQLITE_DONE { return [] }
        guard status == SQLITE_ROW, let current = existingRollouts(home: home) else { return nil }
        let now = Date()
        var candidates: [CodexArchiveCandidate] = []
        do {
            while status == SQLITE_ROW {
                if let candidate = try candidate(from: statement, home: home, current: current, now: now) {
                    candidates.append(candidate)
                }
                status = sqlite3_step(statement)
            }
        } catch {
            return nil
        }
        return status == SQLITE_DONE ? candidates : nil
    }

    private enum RecoveryError: Error { case cannotCheckRollout }

    private static func candidate(
        from row: OpaquePointer, home: URL, current: Set<UUID>, now: Date
    ) throws -> CodexArchiveCandidate? {
        guard let threadText = sqlite3_column_text(row, 0),
              let thread = UUID(uuidString: String(cString: threadText)), !current.contains(thread),
              let pathText = sqlite3_column_text(row, 1),
              sqlite3_column_type(row, 2) == SQLITE_INTEGER,
              let start = timestamp(row, seconds: 3, milliseconds: 4), start <= now else { return nil }
        let tokens = sqlite3_column_int64(row, 2)
        guard tokens > 0 else { return nil }
        let path = String(cString: pathText)
        guard path.hasPrefix("/") else { return nil }
        let original = URL(fileURLWithPath: path).standardizedFileURL
        let basename = plainLogName(original.lastPathComponent)
        guard let basename, threadID(in: basename) == thread else { return nil }
        let paths = possiblePaths(home: home, original: original, basename: basename)
        for path in paths {
            guard let present = presence(of: path) else { throw RecoveryError.cannotCheckRollout }
            if present { return nil }
        }

        let updated = timestamp(row, seconds: 5, milliseconds: 6)
        let archived = timestamp(row, seconds: 7)
        guard updated != nil || (sqlite3_column_type(row, 5) == SQLITE_NULL
                                  && sqlite3_column_type(row, 6) == SQLITE_NULL),
              archived != nil || sqlite3_column_type(row, 7) == SQLITE_NULL else { return nil }
        guard (updated.map { $0 <= now } ?? true), (archived.map { $0 <= now } ?? true) else { return nil }
        let end: Date?
        if let updated, let archived, updated >= start, archived >= start {
            end = max(updated, archived)
        } else {
            end = nil
        }
        return CodexArchiveCandidate(
            threadID: thread.uuidString.lowercased(), tokens: tokens,
            startedAt: start, endedAt: end, logPaths: paths
        )
    }

    private static func timestamp(_ row: OpaquePointer, seconds: Int32, milliseconds: Int32? = nil) -> Date? {
        guard sqlite3_column_type(row, seconds) == SQLITE_INTEGER else { return nil }
        let epoch = sqlite3_column_int64(row, seconds)
        guard epoch > 0 else { return nil }
        if let milliseconds, sqlite3_column_type(row, milliseconds) == SQLITE_INTEGER {
            let precise = sqlite3_column_int64(row, milliseconds)
            guard precise / 1_000 == epoch else { return nil }
            return Date(timeIntervalSince1970: Double(precise) / 1_000)
        }
        return Date(timeIntervalSince1970: Double(epoch))
    }

    private static func possiblePaths(home: URL, original: URL, basename: String) -> [URL] {
        let parent = original.deletingLastPathComponent()
        let canonicalHome = home.resolvingSymlinksInPath()
        var directories = [parent, parent.resolvingSymlinksInPath()]
        for source in Set([home, canonicalHome]) {
            directories.append(source.appendingPathComponent("archived_sessions", isDirectory: true))
            let stamp = String(basename.dropFirst("rollout-".count).prefix(10))
            let parts = stamp.split(separator: "-", omittingEmptySubsequences: false)
            if basename.hasPrefix("rollout-"), parts.map(\.count) == [4, 2, 2],
               parts.allSatisfy({ $0.allSatisfy(\.isASCII) && Int($0) != nil }) {
                let sessions = source.appendingPathComponent("sessions", isDirectory: true)
                directories.append(parts.reduce(sessions) { $0.appendingPathComponent(String($1), isDirectory: true) })
            }
        }
        return Set(directories.flatMap { directory in
            let plain = directory.appendingPathComponent(basename).standardizedFileURL
            return [plain, plain.appendingPathExtension("zst")]
        }).sorted { $0.path < $1.path }
    }

    private static func existingRollouts(home: URL) -> Set<UUID>? {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var known: Set<UUID> = []
        for folder in ["sessions", "archived_sessions"] {
            let directory = home.appendingPathComponent(folder, isDirectory: true).resolvingSymlinksInPath()
            guard let present = presence(of: directory) else { return nil }
            if !present { continue }
            var completed = true
            guard let entries = manager.enumerator(
                at: directory, includingPropertiesForKeys: Array(keys),
                options: [], errorHandler: { _, _ in completed = false; return false }
            ) else { return nil }
            for case let url as URL in entries {
                guard let properties = try? url.resourceValues(forKeys: keys), properties.isSymbolicLink != true
                else { return nil }
                guard let basename = plainLogName(url.lastPathComponent) else { continue }
                guard properties.isRegularFile == true, let id = threadID(in: basename) else { return nil }
                known.insert(id)
            }
            if !completed { return nil }
        }
        return known
    }

    private static func plainLogName(_ filename: String) -> String? {
        if filename.hasSuffix(".jsonl.zst") { return String(filename.dropLast(4)) }
        return filename.hasSuffix(".jsonl") ? filename : nil
    }

    private static func threadID(in basename: String) -> UUID? {
        UUID(uuidString: String(basename.dropLast(".jsonl".count).suffix(36)))
    }

    // Foundation's fileExists returns false for some permission failures too.
    private static func presence(of url: URL) -> Bool? {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 { return true }
        return errno == ENOENT ? false : nil
    }
}
