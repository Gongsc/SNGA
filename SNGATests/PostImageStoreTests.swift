import AppKit
import XCTest
@testable import SNGA

/// 配图缓存的核心保证：原图再大，进内存的也只是正文栏用得上的那点分辨率。
///
/// 这正是图多的话题会把应用卡死的原因 —— 一层几十张手机截图按原始像素解码，
/// 一张就是十几 MB。
@MainActor
final class PostImageStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubImageProtocol.reset()
    }

    override func tearDown() {
        StubImageProtocol.reset()
        super.tearDown()
    }

    func testLargeImageIsDecodedAtDisplayResolution() async throws {
        let url = try imageURL("large.png")
        StubImageProtocol.stub(url, data: try Self.pngData(width: 3000, height: 2000))
        let store = PostImageStore(session: Self.makeSession())

        let result = await store.image(for: url, displayWidth: 570)
        let rendered = try XCTUnwrap(result)
        XCTAssertEqual(rendered.pixelSize, CGSize(width: 3000, height: 2000), "原始尺寸要如实报出来")

        let decoded = rendered.image.size
        XCTAssertLessThan(decoded.width, 3000, "3000px 宽的原图不应该按原尺寸进内存")
        XCTAssertGreaterThanOrEqual(decoded.width, 570, "解码宽度不能低于显示宽度，否则会糊")
        XCTAssertEqual(
            decoded.width / decoded.height,
            3000.0 / 2000.0,
            accuracy: 0.02,
            "缩码不能改变长宽比"
        )
    }

    /// 竖着的手机截图长边是高不是宽。按长边限尺寸会把它压成半宽的糊图，
    /// 缩码必须换算成显示宽度。
    func testTallScreenshotKeepsDisplayWidthResolution() async throws {
        let url = try imageURL("screenshot.png")
        StubImageProtocol.stub(url, data: try Self.pngData(width: 1170, height: 2532))
        let store = PostImageStore(session: Self.makeSession())

        let result = await store.image(for: url, displayWidth: 570)
        let rendered = try XCTUnwrap(result)
        XCTAssertGreaterThanOrEqual(rendered.image.size.width, 570)
        XCTAssertEqual(
            rendered.image.size.width / rendered.image.size.height,
            1170.0 / 2532.0,
            accuracy: 0.02
        )
    }

    func testSmallImageIsNotUpscaled() async throws {
        let url = try imageURL("small.png")
        StubImageProtocol.stub(url, data: try Self.pngData(width: 120, height: 90))
        let store = PostImageStore(session: Self.makeSession())

        let result = await store.image(for: url, displayWidth: 570)
        let rendered = try XCTUnwrap(result)
        XCTAssertEqual(rendered.image.size, CGSize(width: 120, height: 90))
    }

    func testDecodedImageIsReusedWithoutRefetching() async throws {
        let url = try imageURL("cached.png")
        StubImageProtocol.stub(url, data: try Self.pngData(width: 800, height: 600))
        let store = PostImageStore(session: Self.makeSession())

        _ = await store.image(for: url, displayWidth: 570)
        _ = await store.image(for: url, displayWidth: 570)
        XCTAssertEqual(StubImageProtocol.requestCount(for: url), 1)
        XCTAssertNotNil(store.cachedImage(for: url, displayWidth: 570))
    }

    /// 同一张图在正文栏和热点回复区宽度不同，但一次下载就够了。
    func testConcurrentRequestsShareOneDownload() async throws {
        let url = try imageURL("shared.png")
        StubImageProtocol.stub(url, data: try Self.pngData(width: 800, height: 600))
        let store = PostImageStore(session: Self.makeSession())

        async let first = store.image(for: url, displayWidth: 570)
        async let second = store.image(for: url, displayWidth: 570)
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 2)
        XCTAssertEqual(StubImageProtocol.requestCount(for: url), 1)
    }

    /// 原始尺寸要单独记着：位图被腾出内存之后，版面仍然按真实比例预留高度，
    /// 回滚时不会先塌下去再弹回来。
    func testPixelSizeSurvivesForLayoutAfterLoad() async throws {
        let url = try imageURL("remembered.png")
        StubImageProtocol.stub(url, data: try Self.pngData(width: 1600, height: 900))
        let store = PostImageStore(session: Self.makeSession())

        XCTAssertNil(store.pixelSize(for: url))
        _ = await store.image(for: url, displayWidth: 570)
        XCTAssertEqual(store.pixelSize(for: url), CGSize(width: 1600, height: 900))
    }

    func testFailedImageIsRememberedAndNotRetriedOnItsOwn() async throws {
        let url = try imageURL("missing.png")
        StubImageProtocol.stub(url, data: Data(), statusCode: 404)
        let store = PostImageStore(session: Self.makeSession())

        let first = await store.image(for: url, displayWidth: 570)
        XCTAssertNil(first)
        XCTAssertTrue(store.hasFailed(url))
        let second = await store.image(for: url, displayWidth: 570)
        XCTAssertNil(second)
        XCTAssertEqual(StubImageProtocol.requestCount(for: url), 1, "失败之后不该反复重试")
    }

    /// 但用户主动点「重试」时必须真的再取一次 —— 失败记录清不掉的话，
    /// 重试按钮就是个摆设。
    func testRetryAfterFailureFetchesAgain() async throws {
        let url = try imageURL("flaky.png")
        StubImageProtocol.stub(url, data: Data(), statusCode: 500)
        let store = PostImageStore(session: Self.makeSession())

        let failed = await store.image(for: url, displayWidth: 570)
        XCTAssertNil(failed)

        StubImageProtocol.stub(url, data: try Self.pngData(width: 800, height: 600))
        store.forgetFailure(url)
        let recovered = await store.image(for: url, displayWidth: 570)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(StubImageProtocol.requestCount(for: url), 2)
    }

    func testUndecodableDataFailsWithoutCrashing() async throws {
        let url = try imageURL("garbage.png")
        StubImageProtocol.stub(url, data: Data("not an image".utf8))
        let store = PostImageStore(session: Self.makeSession())

        let result = await store.image(for: url, displayWidth: 570)
        XCTAssertNil(result)
        XCTAssertTrue(store.hasFailed(url))
    }

    // MARK: - 辅助

    private func imageURL(_ name: String) throws -> URL {
        try XCTUnwrap(URL(string: "https://img.nga.cn/attachments/mon_202607/23/\(name)"))
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubImageProtocol.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private static func pngData(width: Int, height: Int) throws -> Data {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}

/// 把图片请求拦在本地，测试不依赖网络。
final class StubImageProtocol: URLProtocol {
    private struct Stub {
        let data: Data
        let statusCode: Int
    }

    private nonisolated(unsafe) static var stubs: [URL: Stub] = [:]
    private nonisolated(unsafe) static var requestCounts: [URL: Int] = [:]
    private static let lock = NSLock()

    static func stub(_ url: URL, data: Data, statusCode: Int = 200) {
        lock.withLock { stubs[url] = Stub(data: data, statusCode: statusCode) }
    }

    static func requestCount(for url: URL) -> Int {
        lock.withLock { requestCounts[url] ?? 0 }
    }

    static func reset() {
        lock.withLock {
            stubs.removeAll()
            requestCounts.removeAll()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return lock.withLock { stubs[url] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let stub = Self.lock.withLock({
                  Self.requestCounts[url, default: 0] += 1
                  return Self.stubs[url]
              }),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
