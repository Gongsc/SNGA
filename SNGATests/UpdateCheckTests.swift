import XCTest
@testable import SNGA

final class AppVersionOrderTests: XCTestCase {
    func testANewerPatchMajorOrMinorCounts() {
        XCTAssertTrue(AppVersionOrder.isNewer("2.0.1", than: "2.0.0"))
        XCTAssertTrue(AppVersionOrder.isNewer("2.1.0", than: "2.0.9"))
        XCTAssertTrue(AppVersionOrder.isNewer("3.0.0", than: "2.9.9"))
    }

    func testTheSameVersionIsNotNewer() {
        XCTAssertFalse(AppVersionOrder.isNewer("2.0.0", than: "2.0.0"))
    }

    func testAnOlderVersionIsNotNewer() {
        XCTAssertFalse(AppVersionOrder.isNewer("1.9.0", than: "2.0.0"))
        XCTAssertFalse(AppVersionOrder.isNewer("2.0.0", than: "2.0.1"))
    }

    /// 字符串序会说 `"10" < "9"`，版本号上正好相反。
    func testSegmentsCompareAsNumbersNotAsText() {
        XCTAssertTrue(AppVersionOrder.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(AppVersionOrder.isNewer("1.9.0", than: "1.10.0"))
        XCTAssertTrue(AppVersionOrder.isNewer("10.0.0", than: "9.0.0"))
    }

    func testMissingSegmentsCountAsZero() {
        XCTAssertFalse(AppVersionOrder.isNewer("2.0", than: "2.0.0"))
        XCTAssertFalse(AppVersionOrder.isNewer("2", than: "2.0.0"))
        XCTAssertTrue(AppVersionOrder.isNewer("2.0.1", than: "2.0"))
    }

    /// 仓库的 tag 不带 `v`，但带了也不该把整串读废。
    func testALeadingVPrefixIsIgnored() {
        XCTAssertEqual(AppVersionOrder.normalized("v2.0.0"), "2.0.0")
        XCTAssertEqual(AppVersionOrder.normalized("V2.0.0"), "2.0.0")
        XCTAssertTrue(AppVersionOrder.isNewer("v2.0.1", than: "2.0.0"))
    }

    /// `/releases/latest` 不返回预发布，真拿到了也按前面的数字算。
    func testAPrereleaseSuffixIsTrimmedRatherThanFailingToParse() {
        XCTAssertEqual(AppVersionOrder.normalized("2.1.0-beta1"), "2.1.0")
        XCTAssertEqual(AppVersionOrder.normalized("2.1.0+build7"), "2.1.0")
        XCTAssertTrue(AppVersionOrder.isNewer("2.1.0-beta1", than: "2.0.0"))
        XCTAssertFalse(AppVersionOrder.isNewer("2.0.0-beta1", than: "2.0.0"))
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(AppVersionOrder.normalized("  2.0.0\n"), "2.0.0")
    }
}

final class UpdateCheckerTests: XCTestCase {
    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: UpdateCheckerTests.self)
                .url(forResource: "github-release-latest", withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    func testReadsTheVersionAndPageOutOfARealResponse() throws {
        let release = try GitHubReleaseUpdateChecker.release(from: try fixtureData())
        XCTAssertEqual(release.version, "2.0.0")
        XCTAssertEqual(
            release.pageURL,
            URL(string: "https://github.com/Gongsc/SNGA/releases/tag/2.0.0")
        )
    }

    func testAnOlderInstallIsToldAboutTheNewRelease() async throws {
        let checker = GitHubReleaseUpdateChecker(
            transport: StubTransport(data: try fixtureData(), status: 200)
        )
        let result = try await checker.checkForUpdate(currentVersion: "1.9.0")
        XCTAssertEqual(
            result,
            .updateAvailable(AppRelease(
                version: "2.0.0",
                pageURL: URL(string: "https://github.com/Gongsc/SNGA/releases/tag/2.0.0")
            ))
        )
    }

    func testMatchingTheLatestTagReportsUpToDate() async throws {
        let checker = GitHubReleaseUpdateChecker(
            transport: StubTransport(data: try fixtureData(), status: 200)
        )
        let result = try await checker.checkForUpdate(currentVersion: "2.0.0")
        XCTAssertEqual(result, .upToDate)
    }

    /// 本地版本比线上还新（开发机上就是这样）不该报「有更新」。
    func testRunningAheadOfTheLatestTagReportsUpToDate() async throws {
        let checker = GitHubReleaseUpdateChecker(
            transport: StubTransport(data: try fixtureData(), status: 200)
        )
        let result = try await checker.checkForUpdate(currentVersion: "2.1.0")
        XCTAssertEqual(result, .upToDate)
    }

    func testTheRequestAsksGitHubForAPinnedAPIVersionAndCarriesNoCookies() async throws {
        let transport = RecordingStubTransport(data: try fixtureData(), status: 200)
        let checker = GitHubReleaseUpdateChecker(transport: transport)
        _ = try await checker.checkForUpdate(currentVersion: "2.0.0")

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            "application/vnd.github+json"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-GitHub-Api-Version"),
            "2022-11-28"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// 没有任何 Release 时 GitHub 回 404，要说「还没发布过版本」而不是「已是最新」。
    func testAnEmptyRepositoryIsReportedRatherThanCalledUpToDate() async {
        let checker = GitHubReleaseUpdateChecker(
            transport: StubTransport(data: Data("{}".utf8), status: 404)
        )
        await XCTAssertThrowsErrorAsync(
            try await checker.checkForUpdate(currentVersion: "2.0.0")
        ) { error in
            XCTAssertEqual(error as? UpdateCheckError, .noRelease)
        }
    }

    /// 限流时 GitHub 回的是 403，靠 `X-RateLimit-Remaining` 才分得出来。
    func testRateLimitingIsNamedRatherThanShownAsAPlain403() async {
        let checker = GitHubReleaseUpdateChecker(
            transport: StubTransport(
                data: Data("{}".utf8),
                status: 403,
                headers: ["X-RateLimit-Remaining": "0"]
            )
        )
        await XCTAssertThrowsErrorAsync(
            try await checker.checkForUpdate(currentVersion: "2.0.0")
        ) { error in
            XCTAssertEqual(error as? UpdateCheckError, .rateLimited)
        }
    }

    func testAForbiddenResponseThatIsNotRateLimitingStaysAServerError() async {
        let checker = GitHubReleaseUpdateChecker(
            transport: StubTransport(
                data: Data("{}".utf8),
                status: 403,
                headers: ["X-RateLimit-Remaining": "37"]
            )
        )
        await XCTAssertThrowsErrorAsync(
            try await checker.checkForUpdate(currentVersion: "2.0.0")
        ) { error in
            XCTAssertEqual(error as? UpdateCheckError, .server(403))
        }
    }

    func testRubbishInTheBodyIsAnErrorRatherThanAFalseUpToDate() async {
        let checker = GitHubReleaseUpdateChecker(
            transport: StubTransport(data: Data("<html>not json</html>".utf8), status: 200)
        )
        await XCTAssertThrowsErrorAsync(
            try await checker.checkForUpdate(currentVersion: "2.0.0")
        ) { error in
            XCTAssertEqual(error as? UpdateCheckError, .invalidResponse)
        }
    }
}

// MARK: - 测试替身

private struct StubTransport: HTTPTransport {
    var data: Data
    var status: Int
    var headers: [String: String] = [:]

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (data, response)
    }
}

private final class RecordingStubTransport: HTTPTransport, @unchecked Sendable {
    let data: Data
    let status: Int
    private(set) var lastRequest: URLRequest?

    init(data: Data, status: Int) {
        self.data = data
        self.status = status
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (data, response)
    }
}

/// `XCTAssertThrowsError` 不吃 `async`，补一个。
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (any Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("本该抛错，却正常返回了", file: file, line: line)
    } catch {
        handler(error)
    }
}
