import Combine
import Foundation

@MainActor
final class GitHubUpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case unpublished
        case failed
    }

    let repositoryURL: URL
    @Published private(set) var state: State = .idle

    private let latestReleaseURL: URL
    private let currentVersion: Version?
    private let session: URLSession

    init(
        owner: String,
        repository: String,
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        repositoryURL = URL(string: "https://github.com")!
            .appendingPathComponent(owner)
            .appendingPathComponent(repository)
        latestReleaseURL = URL(string: "https://api.github.com/repos")!
            .appendingPathComponent(owner)
            .appendingPathComponent(repository)
            .appendingPathComponent("releases/latest")
        self.currentVersion = Version(currentVersion)
        self.session = session
    }

    func check() async {
        guard state != .checking, !Task.isCancelled else { return }
        let previousState = state
        state = .checking
        do {
            let result = try await fetch()
            state = Task.isCancelled ? previousState : result
        } catch {
            state = Task.isCancelled ? previousState : .failed
        }
    }

    func checkPeriodically() async {
        while !Task.isCancelled {
            await check()
            do {
                try await Task.sleep(for: .seconds(24 * 60 * 60))
            } catch {
                return
            }
        }
    }

    private func fetch() async throws -> State {
        guard let currentVersion else { return .failed }
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme == "https",
              response.url?.host == "api.github.com"
        else { return .failed }
        if response.statusCode == 404 { return .unpublished }
        guard response.statusCode == 200 else { return .failed }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return .unpublished }
        guard let version = Version(release.tagName) else { return .failed }
        guard version > currentVersion else { return .upToDate }

        let url = repositoryURL.appendingPathComponent("releases/tag").appendingPathComponent(release.tagName)
        return .available(version: version.name, url: url)
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
    }

    private struct Version: Comparable {
        let name: String
        private let components: [Int]

        init?(_ tag: String) {
            name = tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count),
                  parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
            else { return nil }
            let values = parts.compactMap { Int($0) }
            guard values.count == parts.count else { return nil }
            components = values + Array(repeating: 0, count: 3 - values.count)
        }

        static func == (left: Self, right: Self) -> Bool {
            left.components == right.components
        }

        static func < (left: Self, right: Self) -> Bool {
            left.components.lexicographicallyPrecedes(right.components)
        }
    }
}
