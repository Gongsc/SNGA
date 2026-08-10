import AppKit
import Observation

/// NGA 表情的图片缓存。
///
/// 表情来自一个固定的小图集合，同一张会在大量楼层里反复出现，因此按 URL 缓存后
/// 命中率很高。原生渲染分支需要在构建 `Text` 时同步拿到 `NSImage`，所以这里保存
/// 已解码的图片，并在下载完成后通过 `@Observable` 通知相关视图重绘。
@MainActor
@Observable
final class EmoticonImageStore {
    static let shared = EmoticonImageStore()

    /// 表情图集合有限，上限只是防止异常输入把缓存撑大。
    private static let capacity = 400

    private var images: [URL: NSImage] = [:]
    @ObservationIgnored private var failedURLs: Set<URL> = []
    @ObservationIgnored private var inFlightURLs: Set<URL> = []
    @ObservationIgnored private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 取一张表情。尚未缓存时发起一次下载，完成后视图会被重新求值。
    func image(for url: URL) -> NSImage? {
        if let image = images[url] { return image }
        load(url)
        return nil
    }

    /// 与楼层样式表里的 `.nga-smile{max-width:64px;max-height:64px}` 保持一致。
    /// `Text(Image(...))` 按图片自身尺寸内联排版，因此尺寸要在这里定好。
    private static let maximumSide: CGFloat = 64

    private static func capped(_ image: NSImage) -> NSImage {
        let size = image.size
        let longestSide = max(size.width, size.height)
        guard longestSide > maximumSide, longestSide > 0 else { return image }
        let scale = maximumSide / longestSide
        image.size = NSSize(
            width: (size.width * scale).rounded(),
            height: (size.height * scale).rounded()
        )
        return image
    }

    private func load(_ url: URL) {
        guard !inFlightURLs.contains(url), !failedURLs.contains(url) else { return }
        inFlightURLs.insert(url)
        Task { [session] in
            defer { inFlightURLs.remove(url) }
            do {
                let (data, response) = try await session.data(from: url)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let image = NSImage(data: data) else {
                    failedURLs.insert(url)
                    return
                }
                if images.count >= Self.capacity { images.removeAll(keepingCapacity: true) }
                images[url] = Self.capped(image)
            } catch {
                // 表情加载失败只影响这一张，正文其余部分照常显示。
                failedURLs.insert(url)
            }
        }
    }
}
