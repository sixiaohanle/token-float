import Foundation
import SQLite3

@MainActor
func checkLedger() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("usage.sqlite3")
    let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: noon)!
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: noon)!
    let todayKey = UsageDayKey.make(for: noon)
    let earlierKey = UsageDayKey.make(for: yesterday)
    let laterKey = UsageDayKey.make(for: tomorrow)
    let source = LocalUsageLedger.sourceKey(provider: .codex, home: root)
    let other = LocalUsageLedger.sourceKey(provider: .claude, home: root)
    let suite = "com.xiaohan.token-float.ledger-check." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let old = UsageHistory(defaults: defaults)
    old.record(DailyTokenSnapshot(total: 150, complete: true), for: .codex, home: root, at: noon)
    let before = HistoryUsageEvent(id: "old", time: noon.addingTimeInterval(-1), tokens: 100)
    let raw = root.appendingPathComponent("session.jsonl")
    try Data("fixture".utf8).write(to: raw)
    let revision = HistoryLogRevision(url: raw, modified: noon, size: 7, identity: "fixture")
    do {
        let ledger = LocalUsageLedger(url: url, now: noon)
        precondition(ledger.isAvailable && ledger.needsImport(revision, source: source))
        precondition(ledger.record([before], source: source, file: revision)?[todayKey]?.beforeMigration == 100)
        precondition(!ledger.needsImport(revision, source: source))
        precondition(ledger.record([before], source: source)?.isEmpty == true)
    }

    try FileManager.default.removeItem(at: raw)
    let ledger = LocalUsageLedger(url: url, now: tomorrow)
    let history = UsageHistory(defaults: defaults, ledger: ledger)
    precondition(!ledger.needsImport(revision, source: source))
    precondition(history.snapshot(for: .codex, home: root, at: noon)?.total == 150)
    let after = HistoryUsageEvent(id: "new", time: noon.addingTimeInterval(1), tokens: 20)
    let afterChange = ledger.record([after, before], source: source)!
    history.receive(afterChange, source: source)
    precondition(history.snapshot(for: .codex, home: root, at: noon)?.total == 170)

    let legacy = HistoryUsageEvent(id: "legacy", time: yesterday, tokens: 30, legacyGroup: "turn")
    let modern = HistoryUsageEvent(id: "modern", time: yesterday, tokens: 35, supersedesLegacy: ["turn"])
    let first = ledger.record([legacy], source: source)!
    let second = ledger.record([modern], source: source)!
    history.receive(second, source: source)
    history.receive(first, source: source)
    precondition(history.snapshot(for: .codex, home: root, at: yesterday)?.total == 35)
    precondition(ledger.record([modern, legacy], source: source)?.isEmpty == true)

    let later = HistoryUsageEvent(id: "same-response", time: tomorrow, tokens: 42)
    let earlier = HistoryUsageEvent(id: "same-response", time: yesterday, tokens: 40)
    history.receive(ledger.record([later], source: other)!, source: other)
    let moved = ledger.record([earlier], source: other)!
    history.receive(moved, source: other)
    precondition(moved[laterKey]?.hasEvents == false && moved[earlierKey]?.beforeMigration == 42)
    precondition(history.snapshot(for: .claude, home: root, at: tomorrow) == nil)
    precondition(history.rows(homes: [.codex: root, .claude: root], since: nil).map(\.total) == [170, 77])
    let restored = UsageHistory(defaults: defaults, ledger: LocalUsageLedger(url: url))
    precondition(restored.rows(homes: [.codex: root, .claude: root], since: nil).map(\.total) == [170, 77])
    print("PASS checkpoints, removal/restart/new usage, legacy migration, duplicate imports, source isolation, and midnight corrections")

    func date(_ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }
    let exact = CodexArchiveCandidate(
        threadID: "exact", tokens: 15, startedAt: date(6, 1), endedAt: date(6, 1), logPaths: []
    )
    let month = CodexArchiveCandidate(
        threadID: "month", tokens: 25, startedAt: date(5, 1), endedAt: date(5, 2), logPaths: []
    )
    let undated = CodexArchiveCandidate(
        threadID: "undated", tokens: 35, startedAt: date(4, 30), endedAt: date(5, 1), logPaths: []
    )
    let overlappingFile = CodexArchiveCandidate(
        threadID: "checkpointed", tokens: 1_000, startedAt: date(6, 1), endedAt: date(6, 1), logPaths: [raw]
    )
    let candidates = [exact, month, undated, overlappingFile]
    let recovered = ledger.recordVerifiedArchives(candidates + candidates, source: source, oldestLegacyDay: todayKey)!
    precondition(recovered.days == ["2026-06-01": 15])
    precondition(recovered.months == ["2026-05": 25])
    precondition(recovered.undated == 35 && recovered.outsideDaily == 60)
    history.receive([:], recovered: recovered, source: source)
    precondition(history.rows(homes: [.codex: root], since: nil).map(\.total) == [170, 35, 15])
    precondition(history.archiveUsage(homes: [.claude: root]).outsideDaily == 0)

    var replacedArchive: ArchiveUsageTotals?
    let restoredUsage = HistoryUsageEvent(id: "restored-original", time: date(5, 2), tokens: 24, threadID: "MONTH")
    let restoredDays = ledger.record([restoredUsage], source: source) { replacedArchive = $0 }!
    precondition(replacedArchive?.months.isEmpty == true)
    precondition(restoredDays["2026-05-02"]?.revision == replacedArchive?.revision)
    history.receive(restoredDays, recovered: replacedArchive, source: source)
    history.receive([:], recovered: recovered, source: source)
    precondition(history.archiveUsage(homes: [.codex: root]).outsideDaily == 35)
    precondition(history.rows(homes: [.codex: root], since: nil).map(\.total) == [170, 35, 15, 24])
    let reopenedLedger = LocalUsageLedger(url: url)
    let rescanned = reopenedLedger.recordVerifiedArchives(candidates, source: source, oldestLegacyDay: todayKey)!
    precondition(rescanned.months.isEmpty && rescanned.days == recovered.days && rescanned.undated == 35)
    let unknownEnd = CodexArchiveCandidate(
        threadID: "unknown-end", tokens: 50, startedAt: date(4, 1), endedAt: nil, logPaths: []
    )
    precondition(reopenedLedger.recordVerifiedArchives([unknownEnd], source: source, oldestLegacyDay: todayKey)?.undated == 35)
    let cleanSource = LocalUsageLedger.sourceKey(provider: .codex, home: root.appendingPathComponent("new-home"))
    precondition(reopenedLedger.recordVerifiedArchives([unknownEnd], source: cleanSource, oldestLegacyDay: nil)?.undated == 50)

    let upgradeURL = root.appendingPathComponent("pre-owner.sqlite3")
    var previousDatabase: OpaquePointer?
    precondition(sqlite3_open(upgradeURL.path, &previousDatabase) == SQLITE_OK)
    precondition(sqlite3_exec(previousDatabase, """
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value REAL NOT NULL);
        INSERT INTO metadata VALUES ('migration', \(noon.timeIntervalSince1970));
        CREATE TABLE totals (
            source TEXT, day TEXT, before INTEGER, after INTEGER, PRIMARY KEY (source, day)
        ) WITHOUT ROWID;
        INSERT INTO totals VALUES ('\(source)', '2026-06-01', 10, 0);
        """, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(previousDatabase)
    let upgradedLedger = LocalUsageLedger(url: upgradeURL)
    let upgradedArchive = upgradedLedger.recordVerifiedArchives([exact, month], source: source, oldestLegacyDay: nil)!
    precondition(upgradedArchive.days.isEmpty && upgradedArchive.months == recovered.months)
    print("PASS exact day, month only, undated total, previously imported path, repeated recovery and atomic replacement by raw usage")

    let backend = CodexArchiveCandidate(
        threadID: "local-backend", tokens: 80, startedAt: date(6, 2), endedAt: nil, logPaths: []
    )
    let direct = reopenedLedger.recordBackendArchives([backend, backend, exact, overlappingFile], source: source)!
    precondition(direct.backendOnly == 80 && direct.outsideDaily == 115 && direct.days == recovered.days)
    let directHistory = UsageHistory(defaults: defaults, ledger: reopenedLedger)
    precondition(directHistory.rows(homes: [.codex: root], since: nil).map(\.total) == [170, 35, 15, 24])
    precondition(directHistory.archiveUsage(homes: [.codex: root]).outsideDaily == 115)
    let actual = HistoryUsageEvent(id: "backend-original", time: date(6, 2), tokens: 77, threadID: "LOCAL-BACKEND")
    var backendReplacement: ArchiveUsageTotals?
    let actualDays = reopenedLedger.record([actual], source: source) { backendReplacement = $0 }!
    precondition(backendReplacement?.backendOnly == 0 && backendReplacement?.outsideDaily == 35)
    precondition(actualDays["2026-06-02"]?.revision == backendReplacement?.revision)
    precondition(reopenedLedger.recordBackendArchives([backend], source: source)?.backendOnly == 0)
    print("PASS direct backend total only, no double import, previous verified amount kept, original restored once")
}

try MainActor.assumeIsolated { try checkLedger() }
