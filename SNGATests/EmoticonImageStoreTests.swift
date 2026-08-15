import AppKit
import XCTest
@testable import SNGA

/// 表情缓存满了之后必须只淘汰最久没用到的那些。
///
/// 整个清空会让屏幕上所有楼层同时失去表情：表情是行内附件，一张就能把一行从
/// 17 点撑到 56 点，因此高度会集体塌回没有表情的样子，随后又要全部重新下载。
@MainActor
final class EmoticonImageStoreTests: XCTestCase {
    override func tearDown() {
        StubEmoticonProtocol.reset()
        super.tearDown()
    }

    func testEvictionKeepsRecentlyUsedImages() async throws {
        let capacity = 8
        let store = EmoticonImageStore(session: Self.makeSession(), capacity: capacity)
        let urls = try (0..<capacity).map { try Self.stubbedURL($0) }
        for url in urls {
            try await load(url, from: store)
        }
        for url in urls {
            XCTAssertNotNil(store.image(for: url), "装满之前不该淘汰任何一张")
        }

        // 取用最后三张，让它们成为「最近用过」的。
        let recent = Array(urls.suffix(3))
        for url in recent {
            XCTAssertNotNil(store.image(for: url))
        }

        let extra = try Self.stubbedURL(capacity)
        try await load(extra, from: store)

        XCTAssertNotNil(store.image(for: extra), "刚加载的这张必须在")
        for url in recent {
            XCTAssertNotNil(store.image(for: url), "最近用过的不该被淘汰")
        }
        let survivors = urls.filter { store.image(for: $0) != nil }
        XCTAssertFalse(survivors.isEmpty, "不能整个清空")
        XCTAssertLessThan(survivors.count, urls.count, "满了之后应当淘汰掉一些")
    }

    // MARK: - 辅助

    /// 加载一张图并等它落进缓存。
    private func load(_ url: URL, from store: EmoticonImageStore) async throws {
        XCTAssertNil(store.image(for: url), "第一次取应当没有，并触发下载")
        let deadline = Date().addingTimeInterval(5)
        while store.image(for: url) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.image(for: url), "表情图没能加载：\(url.lastPathComponent)")
    }

    private static func stubbedURL(_ index: Int) throws -> URL {
        let url = try XCTUnwrap(
            URL(string: "https://img4.nga.cn/ngabbs/post/smile/probe\(index).png")
        )
        StubEmoticonProtocol.stub(url, data: try pngData())
        return url
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubEmoticonProtocol.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private static func pngData() throws -> Data {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 69,
            pixelsHigh: 60,
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
        NSRect(x: 0, y: 0, width: 69, height: 60).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}

/// 把表情请求拦在本地。
final class StubEmoticonProtocol: URLProtocol {
    private nonisolated(unsafe) static var stubs: [URL: Data] = [:]
    private static let lock = NSLock()

    static func stub(_ url: URL, data: Data) {
        lock.withLock { stubs[url] = data }
    }

    static func reset() {
        lock.withLock { stubs.removeAll() }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return lock.withLock { stubs[url] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let data = Self.lock.withLock({ Self.stubs[url] }),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
