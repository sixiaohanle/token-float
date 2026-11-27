import Foundation

private struct AntigravityFileStamp: Equatable {
    let modified: Date
    let size: UInt64
    let identity: LiveLogFileStatus.Identity

    init?(_ url: URL) {
        guard let status = LiveLogFileStatus(url) else { return nil }
        modified = status.modified
        size = status.size
        identity = status.identity
    }
}

private struct AntigravityRevision: Equatable {
    let database: AntigravityFileStamp
    let wal: AntigravityFileStamp?

    init?(_ url: URL) {
        guard let database = AntigravityFileStamp(url) else { return nil }
        self.database = database
        wal = AntigravityFileStamp(URL(fileURLWithPath: url.path + "-wal"))
    }

    var modified: Date { max(database.modified, wal?.modified ?? .distantPast) }

    func historyRevision(for url: URL) -> HistoryLogRevision {
        let dbIdentity = "\(database.identity.device):\(database.identity.inode):\(database.size)"
        let walIdentity = wal.map {
            "\($0.identity.device):\($0.identity.inode):\($0.size):\($0.modified.timeIntervalSince1970)"
        } ?? "-"
        return HistoryLogRevision(url: url, modified: modified, size: database.size,
                                  identity: "\(dbIdentity):\(database.modified.timeIntervalSince1970)|\(walIdentity)")
    }
}

final class AntigravityMeter {
    static let antigravityHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini", isDirectory: true)

    private struct Reading {
        let revision: AntigravityRevision
        let sample: AntigravitySample?
        let retryAfter: Date
    }

    private let directories: [URL]
    private let freshness: TimeInterval = 20
    private let visibility: TimeInterval = 120
    private var readings: [URL: Reading] = [:]
    private var databases: [URL] = []
    private var discoveredDates: [URL: Date] = [:]
    private var nextIndex = 0
    private var nextDiscovery = Date.distantPast
    private var available = false

    init(home: URL = AntigravityMeter.antigravityHome) {
        directories = Self.conversationDirectories(in: home)
    }

    fileprivate static func conversationDirectories(in home: URL) -> [URL] {
        if home.lastPathComponent == "conversations" { return [home] }
        return ["conversations", "antigravity/conversations", "antigravity-ide/conversations"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
    }

    func sample(now: Date = Date()) -> MeterSnapshot {
        if now >= nextDiscovery {
            discover(now: now)
            nextDiscovery = now.addingTimeInterval(0.75)
        }
        refresh(now: now)

        // The app and IDE can keep separate copies of the same conversation.
        var latest: [String: AntigravitySample] = [:]
        for (url, reading) in readings {
            guard let sample = reading.sample, sample.endedAt <= now,
                  now.timeIntervalSince(sample.endedAt) <= visibility else { continue }
            let id = url.deletingPathExtension().lastPathComponent.lowercased()
            if let existing = latest[id] {
                if existing.endedAt > sample.endedAt { continue }
                if existing.endedAt == sample.endedAt && existing.outputTokens >= sample.outputTokens { continue }
            }
            latest[id] = sample
        }
        let rows = latest.sorted { a, b in
            a.value.endedAt == b.value.endedAt ? a.key < b.key : a.value.endedAt > b.value.endedAt
        }.map { id, sample in
            let rate = Double(sample.outputTokens) / sample.generationSeconds
            let fresh = now.timeIntervalSince(sample.endedAt) <= freshness
            return MeterRow(id: id, title: "对话 · \(id.suffix(6))", rate: fresh ? rate : nil,
                            state: fresh ? .generating : .finished, model: sample.model,
                            outputAt: sample.endedAt, averageRate: rate)
        }
        return MeterSnapshot(rows: rows, sourceAvailable: available)
    }

    private func discover(now: Date) {
        var databasesOnDisk: Set<URL> = []
        var modified: [URL: Date] = [:]
        let cutoff = now.addingTimeInterval(-visibility)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        available = false
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }
            available = true
            for file in files {
                let isDatabase = file.pathExtension == "db"
                guard isDatabase || file.lastPathComponent.hasSuffix(".db-wal"),
                      let attributes = try? file.resourceValues(forKeys: keys),
                      attributes.isRegularFile == true, let date = attributes.contentModificationDate else { continue }
                let name = file.lastPathComponent
                let databaseName = isDatabase ? name : String(name.dropLast(4))
                let database = directory.appendingPathComponent(databaseName, isDirectory: false)
                if isDatabase { databasesOnDisk.insert(database) }
                if date >= cutoff { modified[database] = max(modified[database] ?? .distantPast, date) }
            }
        }
        let candidates = modified.filter { databasesOnDisk.contains($0.key) }
        guard candidates != discoveredDates else { return }
        // A previously archived conversation can start writing to its WAL without touching the DB.
        // Read new/changed conversations first, even in a directory with years of older sessions.
        let changed = candidates.filter { discoveredDates[$0.key] != $0.value }.sorted { left, right in
            left.value == right.value ? left.key.path < right.key.path : left.value > right.value
        }.map(\.key)
        discoveredDates = candidates
        readings = readings.filter { candidates[$0.key] != nil }
        let changedSet = Set(changed)
        let remaining = databases[nextIndex...] + databases[..<nextIndex]
        databases = changed + remaining.filter { candidates[$0] != nil && !changedSet.contains($0) }
        nextIndex = 0
    }

    private func refresh(now: Date) {
        // Bound metadata checks and SQLite reads independently on each rate timer tick.
        var reads = 0
        for _ in 0..<min(16, databases.count) {
            let url = databases[nextIndex]
            nextIndex = (nextIndex + 1) % databases.count
            guard let revision = AntigravityRevision(url),
                  now.timeIntervalSince(revision.modified) <= visibility else {
                readings.removeValue(forKey: url)
                continue
            }
            let previous = readings[url]
            if let previous, previous.revision == revision, now < previous.retryAfter { continue }

            let sample = AntigravitySampleReader.latest(in: url).flatMap { sample -> AntigravitySample? in
                guard sample.outputTokens > 0, sample.endedAt > sample.startedAt,
                      sample.generationSeconds.isFinite, sample.generationSeconds > 0,
                      (Double(sample.outputTokens) / sample.generationSeconds).isFinite else { return nil }
                return sample
            }
            // A writer can briefly hold the DB. Keep the last valid observation until its normal
            // expiry, and retry the unchanged revision after the writer has had time to finish.
            let retained = previous?.revision.database.identity == revision.database.identity ? previous?.sample : nil
            readings[url] = Reading(revision: revision, sample: sample ?? retained,
                                    retryAfter: sample == nil ? now.addingTimeInterval(1) : .distantFuture)
            reads += 1
            if reads >= 4 { break }
        }
    }
}


// A usage scan runs on its own serial queue so an initial import cannot delay speed readings.
final class AntigravityUsage {
    private let directories: [URL]
    private var imported: [URL: HistoryLogRevision] = [:]

    init(home: URL = AntigravityMeter.antigravityHome) {
        directories = AntigravityMeter.conversationDirectories(in: home)
    }

    func scan(
        shouldRead: (HistoryLogRevision) -> Bool,
        shouldCancel: () -> Bool,
        receive: (HistoryLogRevision, [HistoryUsageEvent]) -> Void
    ) -> Bool {
        var revisions: [HistoryLogRevision] = []
        var available = false
        var complete = true
        for directory in directories {
            if shouldCancel() { return false }
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            } catch {
                complete = false
                continue
            }
            available = true
            for url in urls where url.pathExtension == "db" {
                guard let revision = AntigravityRevision(url)?.historyRevision(for: url) else { continue }
                revisions.append(revision)
            }
        }
        let present = Set(revisions.map(\.url))
        imported = imported.filter { present.contains($0.key) }
        for revision in revisions.sorted(by: { $0.modified > $1.modified }) {
            if shouldCancel() { return false }
            guard imported[revision.url] != revision else { continue }
            if shouldRead(revision) {
                guard let steps = AntigravitySampleReader.usage(in: revision.url, shouldCancel: shouldCancel) else {
                    complete = false
                    continue
                }
                let id = revision.url.deletingPathExtension().lastPathComponent.lowercased()
                let events = steps.map { step in
                    HistoryUsageEvent(id: "\(id):\(step.stepIndex)", time: step.time, tokens: step.tokens)
                }
                receive(revision, events)
                if shouldCancel() { return false }
            }
            imported[revision.url] = revision
        }
        return available && complete && !shouldCancel()
    }
}
