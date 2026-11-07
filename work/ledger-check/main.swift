import Foundation

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
}

try MainActor.assumeIsolated { try checkLedger() }
