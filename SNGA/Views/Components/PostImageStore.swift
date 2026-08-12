import AppKit
import Foundation
import ImageIO

/// 楼层配图的下载、缩码与缓存。
///
/// 图多的话题以前整层交给 `WKWebView`，而楼层的网页视图高度等于正文全高，
/// WebKit 便把整篇文档都当成可见区域：一层里的几十张手机截图会同时下载、
/// 同时按原始像素解码，一张 1170×2532 的截图解出来就是 12 MB，几十张足以
/// 把内存吃穿，滚动随之卡死。
///
/// 这里做四件事：
/// - 按显示宽度缩码。一张 4000px 宽的原图在 570pt 的正文栏里只需要解到 1140px，
///   内存差着一个数量级。
/// - 给解码结果封一个像素总量上限。缩到显示宽度只对「宽」的图有用，一张
///   1080×24000 的长截图宽度本来就不到栏宽，缩码等于没做，解出来将近 100 MB；
///   超过上限的图整体按比例再缩一档，宁可略糊也不能把内存吃穿。
/// - 解码串行化（`ImageDecoder` 是 actor），快速滚动不会同时炸开一批解码。
/// - 位图放进有总量上限的 `NSCache`，滚过去的图片会被自动腾掉。
///
/// 原始像素尺寸单独记着：位图被腾掉之后，版面仍然能按真实比例预留高度，
/// 回滚时不会先塌成占位高度再弹回去。
@MainActor
final class PostImageStore {
    static let shared = PostImageStore()

    struct Rendered {
        let cgImage: CGImage
        /// 图片的原始像素尺寸，不是解码后的尺寸。版面按它算比例和固有宽度。
        let pixelSize: CGSize
    }

    /// 已解码位图的总量上限，按像素字节数计。
    private static let totalCostLimit = 96 << 20
    /// 记住的原始尺寸数量上限。每项只是两个数字，可以放得比位图宽松得多。
    private static let pixelSizeCapacity = 3000
    /// 解码宽度按此步长归档，窗口宽度的细微变化不会让同一张图反复重解。
    private static let decodeWidthStep = 256

    private final class CacheEntry {
        let cgImage: CGImage
        let pixelSize: CGSize

        init(cgImage: CGImage, pixelSize: CGSize) {
            self.cgImage = cgImage
            self.pixelSize = pixelSize
        }
    }

    private let cache = NSCache<NSString, CacheEntry>()
    private let decoder = ImageDecoder()
    private let session: URLSession
    private var pixelSizes: [URL: CGSize] = [:]
    private var failedURLs: Set<URL> = []
    private var tasks: [String: Task<Rendered?, Never>] = [:]

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
        cache.totalCostLimit = Self.totalCostLimit
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        // 图片是不会变的附件，翻回上一页时直接命中缓存，省掉一次往返。
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 16 << 20,
            diskCapacity: 256 << 20,
            directory: nil
        )
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }

    /// 之前量到过的原始像素尺寸。用来在图片到达之前把版面高度定下来。
    func pixelSize(for url: URL) -> CGSize? {
        pixelSizes[url]
    }

    func hasFailed(_ url: URL) -> Bool {
        failedURLs.contains(url)
    }

    /// 忘掉一次失败，让用户点「重试」时能真的再取一次。
    func forgetFailure(_ url: URL) {
        failedURLs.remove(url)
    }

    /// 已经解码好、还留在缓存里的位图。命中时视图可以直接画出来，不必等一轮 await。
    func cachedImage(for url: URL, displayWidth: CGFloat) -> Rendered? {
        guard let entry = cache.object(forKey: cacheKey(url, displayWidth) as NSString) else {
            return nil
        }
        return Rendered(cgImage: entry.cgImage, pixelSize: entry.pixelSize)
    }

    /// 取一张按显示宽度缩码后的图片。同一张图的并发请求会合流到同一个任务上。
    func image(for url: URL, displayWidth: CGFloat) async -> Rendered? {
        if let cached = cachedImage(for: url, displayWidth: displayWidth) { return cached }
        guard !failedURLs.contains(url) else { return nil }

        let key = cacheKey(url, displayWidth)
        if let existing = tasks[key] { return await existing.value }

        let targetWidth = decodeWidth(displayWidth)
        let task = Task { @MainActor [session, decoder] in
            let decoded = await Self.download(
                url,
                targetWidth: targetWidth,
                session: session,
                decoder: decoder
            )
            return self.finish(decoded, url: url, key: key)
        }
        tasks[key] = task
        return await task.value
    }

    private nonisolated static func download(
        _ url: URL,
        targetWidth: Int,
        session: URLSession,
        decoder: ImageDecoder
    ) async -> DecodedImage? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                return nil
            }
            return await decoder.decode(data, targetWidth: targetWidth)
        } catch {
            // 一张图失败只影响它自己，正文其余部分照常显示。
            return nil
        }
    }

    private func finish(_ decoded: DecodedImage?, url: URL, key: String) -> Rendered? {
        tasks[key] = nil
        guard let decoded else {
            failedURLs.insert(url)
            return nil
        }
        if pixelSizes.count >= Self.pixelSizeCapacity {
            pixelSizes.removeAll(keepingCapacity: true)
        }
        pixelSizes[url] = decoded.pixelSize
        cache.setObject(
            CacheEntry(cgImage: decoded.cgImage, pixelSize: decoded.pixelSize),
            forKey: key as NSString,
            cost: decoded.cgImage.width * decoded.cgImage.height * 4
        )
        return Rendered(cgImage: decoded.cgImage, pixelSize: decoded.pixelSize)
    }

    /// 位图按解码宽度分档缓存：同一张图在正文栏和热点回复区的宽度不同，
    /// 两者各存一份好过来回重解。
    private func cacheKey(_ url: URL, _ displayWidth: CGFloat) -> String {
        "\(url.absoluteString)|\(decodeWidth(displayWidth))"
    }

    /// 目标解码宽度：显示宽度换算成物理像素，再向上归到步长。
    private func decodeWidth(_ displayWidth: CGFloat) -> Int {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = max(1, Int((displayWidth * scale).rounded(.up)))
        let steps = (pixels + Self.decodeWidthStep - 1) / Self.decodeWidthStep
        return steps * Self.decodeWidthStep
    }

    func removeAll() {
        cache.removeAllObjects()
        pixelSizes.removeAll()
        failedURLs.removeAll()
    }
}

/// 解码结果。`CGImage` 是不可变的，跨执行器传递是安全的。
private struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
    /// 缩码之前的原始像素尺寸。
    let pixelSize: CGSize
}

/// 串行解码器。
///
/// actor 的隔离顺带把解码排成了队：一次只解一张，滚得再快也不会同时展开
/// 十几张位图。解码本身在协作线程池上跑，不占主线程。
private actor ImageDecoder {
    /// 解码结果的像素总量上限（约 12 MP，48 MB）。
    ///
    /// 只按显示宽度缩码是不够的：长截图（1080×24000 这种）宽度本来就不到正文栏，
    /// 宽度比例算下来是 1，等于完全不缩，解出来将近 100 MB。这类图整体再缩一档，
    /// 分辨率仍高于一倍图，但内存回到可控范围。
    static let maximumDecodedPixels = 12_000_000

    func decode(_ data: Data, targetWidth: Int) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        // `kCGImageSourceThumbnailMaxPixelSize` 限的是长边，而我们要控的是显示
        // 宽度：竖着的手机截图长边是高，直接把宽度填进去会把它压成半宽的糊图。
        let widthRatio = min(1, CGFloat(targetWidth) / CGFloat(pixelWidth))
        // 长截图的宽度比例是 1，这一档才是真正管住它的那个。
        let area = CGFloat(pixelWidth) * CGFloat(pixelHeight) * widthRatio * widthRatio
        let areaRatio = area > CGFloat(Self.maximumDecodedPixels)
            ? (CGFloat(Self.maximumDecodedPixels) / area).squareRoot()
            : 1
        let ratio = widthRatio * areaRatio
        // 向下取整：往上凑那一个像素会让结果刚好越过总量上限。
        let maxPixelSize = max(
            1,
            Int((CGFloat(max(pixelWidth, pixelHeight)) * ratio).rounded(.down))
        )
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary) else {
            return nil
        }
        return DecodedImage(
            cgImage: cgImage,
            pixelSize: CGSize(width: pixelWidth, height: pixelHeight)
        )
    }
}
