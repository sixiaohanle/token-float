import Foundation

final class ReleaseStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        precondition(url.host == "api.github.com" && url.path.hasSuffix("/releases/latest"))
        precondition(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        let scenario = url.pathComponents[3]
        let status: Int
        let body: String
        switch scenario {
        case "unpublished": (status, body) = (404, "{}")
        case "rate-limited": (status, body) = (403, "{}")
        case "invalid-tag": (status, body) = (200, #"{"tag_name":"current","draft":false,"prerelease":false}"#)
        case "preview": (status, body) = (200, #"{"tag_name":"v1.0.0-beta","draft":false,"prerelease":true}"#)
        default: (status, body) = (200, #"{"tag_name":"v0.7.10","draft":false,"prerelease":false}"#)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
func verifyUpdateCheck() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReleaseStub.self]
    let session = URLSession(configuration: configuration)

    let cases: [(String, String, GitHubUpdateChecker.State)] = [
        ("token-float", "0.7.9", .available(
            version: "0.7.10", url: URL(string: "https://github.com/test/token-float/releases/tag/v0.7.10")!
        )),
        ("token-float", "0.7.10", .upToDate),
        ("token-float", "0.8.0", .upToDate),
        ("unpublished", "0.7.9", .unpublished),
        ("preview", "0.7.9", .unpublished),
        ("rate-limited", "0.7.9", .failed),
        ("invalid-tag", "0.7.9", .failed),
    ]
    for (repository, version, expected) in cases {
        let checker = GitHubUpdateChecker(owner: "test", repository: repository, currentVersion: version, session: session)
        await checker.check()
        precondition(checker.state == expected, "Unexpected result for \(repository) at \(version)")
    }
    print("PASS numeric version ordering, release links, no-release, prerelease and failure handling")
}

await verifyUpdateCheck()
