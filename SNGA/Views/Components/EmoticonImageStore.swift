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
    private let capacity: Int

    private var images: [URL: NSImage] = [:]
    /// 每张图最近一次被取用的次序，只用于淘汰，不参与观察。
    @ObservationIgnored private var lastUsed: [URL: UInt64] = [:]
    @ObservationIgnored private var useTick: UInt64 = 0
    @ObservationIgnored private var failedURLs: Set<URL> = []
    @ObservationIgnored private var inFlightURLs: Set<URL> = []
    @ObservationIgnored private let session: URLSession

    init(session: URLSession = .shared, capacity: Int = 400) {
        self.session = session
        self.capacity = max(1, capacity)
    }

    /// 取一张表情。尚未缓存时发起一次下载，完成后视图会被重新求值。
    func image(for url: URL) -> NSImage? {
        guard let image = images[url] else {
            load(url)
            return nil
        }
        touch(url)
        return image
    }

    /// 记一次取用。写的是未被观察的字段，因此不会把正在求值的视图再标脏。
    private func touch(_ url: URL) {
        useTick += 1
        lastUsed[url] = useTick
    }

    /// 满了只淘汰最久没被取用的那一批。
    ///
    /// 原先是整个清空。表情是行内附件，一张就能把一行从 17 点撑到 56 点，所以清空
    /// 的那一刻，屏幕上每一层的高度都会塌回没有表情的样子，紧接着又要把这些图全部
    /// 重新下载、再长回去。按取用次序淘汰则只会动到早就不在屏幕上的那些。
    private func evictLeastRecentlyUsed() {
        let overflow = images.count - capacity + 1
        guard overflow > 0 else { return }
        // 留出余量，免得此后每加载一张都要淘汰一次。
        let count = min(images.count, overflow + capacity / 10)
        let victims = images.keys
            .sorted { (lastUsed[$0] ?? 0) < (lastUsed[$1] ?? 0) }
            .prefix(count)
        for url in victims {
            images.removeValue(forKey: url)
            lastUsed.removeValue(forKey: url)
        }
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
                evictLeastRecentlyUsed()
                images[url] = Self.capped(image)
                touch(url)
            } catch {
                // 表情加载失败只影响这一张，正文其余部分照常显示。
                failedURLs.insert(url)
            }
        }
    }
}
