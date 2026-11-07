import Foundation

struct HistoryUsageEvent {
    let id: String
    let time: Date
    let tokens: Int64
    var legacyGroup: String? = nil
    var supersedesLegacy: [String] = []
}

struct HistoryLogRevision: Equatable {
    let url: URL
    let modified: Date
    let size: UInt64
    var identity: String = ""
}

enum MeterProvider: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    var historyFolder: String {
        switch self {
        case .codex: "sessions"
        case .claude: "projects"
        }
    }

    var historyFolders: [String] {
        self == .codex ? [historyFolder, "archived_sessions"] : [historyFolder]
    }
}

struct ProviderMeter: Identifiable {
    var provider: MeterProvider
    var snapshot: MeterSnapshot
    var daily: DailyTokenSnapshot?
    var id: MeterProvider { provider }

    var rate: Double? {
        guard snapshot.sourceAvailable else { return nil }
        var hasActive = false
        var sampled: Double?
        for row in snapshot.rows where row.state != .finished {
            hasActive = true
            if let rate = row.rate { sampled = (sampled ?? 0) + rate }
        }
        return sampled ?? (hasActive ? nil : 0)
    }

    static func combinedRate(_ meters: [ProviderMeter]) -> Double? {
        var hasSource = false
        var hasActive = false
        var sampled: Double?
        for meter in meters where meter.snapshot.sourceAvailable {
            hasSource = true
            for row in meter.snapshot.rows where row.state != .finished {
                hasActive = true
                if let rate = row.rate { sampled = (sampled ?? 0) + rate }
            }
        }
        return sampled ?? (hasSource && !hasActive ? 0 : nil)
    }
}

final class WorkspacePathResolver {
    private let fileManager = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    private var cached: [String: String] = [:]

    func project(for path: String) -> String {
        guard path.hasPrefix("/") else { return "其他工作区" }
        if let project = cached[path] { return project }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let result = repository(containing: directory)?.path ?? directory.path
        if cached.count >= 512 { cached.removeAll(keepingCapacity: true) }
        cached[path] = result
        return result
    }

    private func repository(containing directory: URL) -> URL? {
        var candidate = directory
        while candidate.path != "/", candidate.path != home.path {
            let marker = candidate.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return candidate }
                return mainCheckout(from: marker, relativeTo: candidate) ?? candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private func mainCheckout(from marker: URL, relativeTo checkout: URL) -> URL? {
        guard let gitLine = firstLine(at: marker), gitLine.hasPrefix("gitdir: ") else { return nil }
        let gitDirectory = resolve(String(gitLine.dropFirst(8)), relativeTo: checkout)
        guard let relativeCommonDirectory = firstLine(at: gitDirectory.appendingPathComponent("commondir")) else { return nil }
        let commonDirectory = resolve(relativeCommonDirectory, relativeTo: gitDirectory)
        guard commonDirectory.lastPathComponent == ".git" else { return nil }
        return commonDirectory.deletingLastPathComponent()
    }

    private func resolve(_ path: String, relativeTo root: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
        return root.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }

    private func firstLine(at url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 4_096),
              let text = String(data: bytes, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first else { return nil }
        return line.trimmingCharacters(in: .whitespaces)
    }
}
