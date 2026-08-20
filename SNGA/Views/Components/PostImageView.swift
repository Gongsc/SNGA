import AppKit
import SwiftUI

/// 正文里的一张配图。
///
/// 图多的楼层能不能滚得动，取决于四件事，这个视图各管一件：
/// - **先占位，再加载。** 高度取自 `<img>` 自带的尺寸、或 `PostImageStore` 上次量到
///   的原始尺寸；有了高度，图片到达时就不会把下方内容顶走，滚动条也不再乱跳。
/// - **只加载视口附近的图。** 一层里几十张截图不会同时下载解码，滚远之后立刻松开
///   位图，让缓存有机会把它腾掉。松开的距离比加载的距离远一截，来回小幅滚动时
///   不会反复装卸。
/// - **按显示宽度解码。** 原图多大都只解到正文栏用得上的分辨率。
/// - **很高的图切成段画。** 一张图一个 `Image` 就是一个和整图一样高的图层，
///   Core Animation 要为它备下整张的绘制缓冲：1080×16000 的长截图实测占 206 MB，
///   足够把应用拖死。切成十几段、视口外的段只画 `Color.clear` 之后只剩 1 MB ——
///   没有位图内容就没有绘制缓冲。这正是 `WKWebView` 里 WebKit 分块绘制在做的事。
struct PostImageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    let image: PostImage
    var imageFreeMode = false

    /// 提前多远开始加载。约一屏，滚到眼前时通常已经落位。
    private nonisolated static let loadMargin: CGFloat = 900
    /// 滚出多远之后松开位图。留出滞后区间，小幅回滚不会重来一遍。
    private nonisolated static let releaseMargin: CGFloat = 2400
    /// 长图的段要提前多远开始画。够快滚时也不露白，又不至于多画太多。
    private nonisolated static let sliceMargin: CGFloat = 800
    /// 视口范围按这个步长归档。不归档的话滚动每一帧都会改状态，
    /// 一屏几十张图就是每帧几十次重新求值。
    private nonisolated static let windowStep: CGFloat = 200
    /// 尚不知道比例时按 4:3 预留。NGA 的 `[img]` 不带尺寸，占位和真实高度总会有
    /// 出入；取一个接近常见配图的比例，图片到达时下方内容的位移最小。
    private static let unknownAspectRatio: CGFloat = 4.0 / 3.0
    private static let minimumUnknownHeight: CGFloat = 140
    /// 无图模式下的占位高度，与样式表里的 `.snga-image-placeholder` 一致。
    private static let deferredHeight: CGFloat = 58

    /// 已解码的位图，按段切好。空表示还没有可画的内容。
    @State private var slices: [PostImageSlice] = []
    /// `slices` 是按多宽解出来的。窗口变宽时才值得重解一次。
    @State private var renderedWidth: CGFloat = 0
    @State private var measuredPixelSize: CGSize?
    @State private var availableWidth: CGFloat = 0
    @State private var visibility = Visibility()
    @State private var didFail = false
    /// 无图模式下用户点开了这一张。
    @State private var isRevealed = false

    private struct Visibility: Equatable {
        var shouldLoad = false
        var shouldRetain = false
        /// 视口在本视图坐标系里的纵向范围，已经外扩了一段余量。nil 表示无从判断，
        /// 此时所有段都照画。按 `windowStep` 归档，滚动时不会每帧都触发状态更新。
        var window: ClosedRange<CGFloat>?
    }

    private struct LoadTicket: Equatable {
        let url: URL
        let width: CGFloat
        let isEnabled: Bool
        let attempt: Int
    }

    @State private var attempt = 0

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: reservedHeight)
            .overlay(alignment: overlayAlignment) { visual }
            .onGeometryChange(for: Measurements.self) { Self.measurements($0) } action: {
                update($0)
            }
            .task(id: loadTicket) { await load() }
            .onChange(of: visibility.shouldRetain) { _, shouldRetain in
                // 位图只在视口附近留着。尺寸留下，版面不会因此变化。
                guard !shouldRetain else { return }
                slices = []
                renderedWidth = 0
            }
    }

    // MARK: - 版面

    /// 网页上 `img{max-width:100%;height:auto}`：图片按自身像素宽度显示，
    /// 超过正文栏才缩到栏宽。原生分支要照着来，否则小图会被拉大。
    private var displayWidth: CGFloat {
        guard availableWidth > 0 else { return 0 }
        guard let naturalWidth else { return availableWidth }
        return min(naturalWidth, availableWidth)
    }

    private var naturalWidth: CGFloat? {
        if let pixelSize { return pixelSize.width }
        return image.pixelWidth.map(CGFloat.init)
    }

    private var pixelSize: CGSize? {
        measuredPixelSize ?? PostImageStore.shared.pixelSize(for: image.url)
    }

    private var aspectRatio: CGFloat? {
        if let pixelSize, pixelSize.width > 0, pixelSize.height > 0 {
            return pixelSize.width / pixelSize.height
        }
        return image.aspectRatio
    }

    private var reservedHeight: CGFloat {
        if isDeferred { return Self.deferredHeight }
        // 加载失败又不知道原尺寸时不必空出一大片，收成一条提示的高度。
        if didFail, aspectRatio == nil { return Self.deferredHeight }
        guard displayWidth > 0 else { return Self.minimumUnknownHeight }
        guard let aspectRatio, aspectRatio > 0 else {
            return max(
                Self.minimumUnknownHeight,
                (displayWidth / Self.unknownAspectRatio).rounded()
            )
        }
        return max(1, (displayWidth / aspectRatio).rounded())
    }

    private var overlayAlignment: Alignment {
        switch image.alignment {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }

    /// 无图模式下还没被点开。
    private var isDeferred: Bool { imageFreeMode && !isRevealed }

    // MARK: - 可见性

    private struct Measurements: Equatable {
        var width: CGFloat = 0
        var visibility = Visibility()
    }

    private nonisolated static func measurements(_ proxy: GeometryProxy) -> Measurements {
        var result = Measurements(width: proxy.size.width.rounded())
        guard let visible = proxy.bounds(of: .scrollView(axis: .vertical)) else {
            // 不在滚动视图里（回复预览等）就没有远近之分，照常加载。
            result.visibility = Visibility(shouldLoad: true, shouldRetain: true)
            return result
        }
        let local = CGRect(origin: .zero, size: proxy.size)
        let step = Self.windowStep
        let top = ((visible.minY - Self.sliceMargin) / step).rounded(.down) * step
        let bottom = ((visible.maxY + Self.sliceMargin) / step).rounded(.up) * step
        result.visibility = Visibility(
            shouldLoad: visible.insetBy(dx: 0, dy: -Self.loadMargin).intersects(local),
            shouldRetain: visible.insetBy(dx: 0, dy: -Self.releaseMargin).intersects(local),
            window: top...max(top, bottom)
        )
        return result
    }

    private func update(_ measurements: Measurements) {
        availableWidth = measurements.width
        visibility = measurements.visibility
    }

    // MARK: - 加载

    private var loadTicket: LoadTicket {
        LoadTicket(
            url: image.url,
            width: displayWidth,
            isEnabled: visibility.shouldLoad && !isDeferred,
            attempt: attempt
        )
    }

    private func load() async {
        let width = displayWidth
        guard loadTicket.isEnabled, width > 0 else { return }
        // 已经有位图时只有变宽才值得重解：图片到达后 `displayWidth` 会收窄到图片
        // 自身的宽度，那不是重解的理由。
        guard slices.isEmpty || width > renderedWidth + 1 else { return }
        if let cached = PostImageStore.shared.cachedImage(for: image.url, displayWidth: width) {
            apply(cached, width: width)
            return
        }
        didFail = PostImageStore.shared.hasFailed(image.url)
        guard !didFail else { return }
        guard let result = await PostImageStore.shared.image(
            for: image.url,
            displayWidth: width
        ) else {
            didFail = true
            return
        }
        guard !Task.isCancelled else { return }
        apply(result, width: width)
    }

    private func apply(_ result: PostImageStore.Rendered, width: CGFloat) {
        slices = PostImageSlicer.slices(of: result.cgImage)
        renderedWidth = width
        measuredPixelSize = result.pixelSize
        didFail = false
    }

    private func retry() {
        // 失败是记在 store 里的，不清掉的话下一轮 `load()` 会立刻又判定为失败。
        PostImageStore.shared.forgetFailure(image.url)
        didFail = false
        attempt += 1
    }

    // MARK: - 绘制

    @ViewBuilder
    private var visual: some View {
        if isDeferred {
            placeholder(
                title: "▧ 图片 · 点击加载",
                systemImage: nil,
                action: { isRevealed = true }
            )
            .help("点击加载图片")
        } else if !slices.isEmpty {
            picture
                .frame(width: displayWidth, height: reservedHeight)
                .accessibilityElement()
                .accessibilityLabel(image.alt.isEmpty ? "帖子图片" : image.alt)
                .accessibilityAddTraits(.isButton)
                .contentShape(.rect)
                .onTapGesture { model.previewImageURL = image.url }
                .pointerStyle(.link)
                .help("点击查看大图")
                // 复制、另存为这些操作不该等到点开大图才有，正文里右键就能用，
                // 项目和文案与大图预览里的那份完全一致。
                .contextMenu {
                    PostImageContextMenu(
                        url: image.url,
                        onError: { model.imageActionError = $0 }
                    )
                }
        } else if didFail {
            placeholder(
                title: "图片加载失败 · 点击重试",
                systemImage: "arrow.clockwise",
                action: retry
            )
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.fillColor)
                .frame(width: max(displayWidth, 1), height: reservedHeight)
                .accessibilityLabel("图片加载中")
        }
    }

    /// 图片本体。矮图一个 `Image` 就够；高图必须切段，否则一整张的绘制缓冲
    /// 会把内存吃穿。
    ///
    /// 段用普通 `VStack` 而不是 `LazyVStack`：惰性堆栈得替没实例化的段估高度，
    /// 而估值和实测对不上时，实例化会改变内容高度、进而改变滚动位置、再触发
    /// 新一轮实例化 —— 一层套一层的惰性堆栈很容易就这么自激起来。这里每段的
    /// 高度都是算好的，版面精确；省内存靠的是视口外的段画 `Color.clear`：
    /// 没有位图内容就没有绘制缓冲，实测和惰性堆栈一样是 +1 MB。
    @ViewBuilder
    private var picture: some View {
        if slices.count <= 1 {
            slices.first.map { slice in
                Image(nsImage: slice.image)
                    .resizable()
                    .frame(width: displayWidth, height: reservedHeight)
            }
        } else {
            let total = reservedHeight
            let pixelHeight = slices[slices.count - 1].pixelRange.upperBound
            VStack(spacing: 0) {
                ForEach(slices) { slice in
                    let layout = PostImageSlicer.layout(
                        of: slice,
                        totalHeight: total,
                        pixelHeight: pixelHeight
                    )
                    if isVisible(layout) {
                        Image(nsImage: slice.image)
                            .resizable()
                            .frame(width: displayWidth, height: layout.height)
                    } else {
                        Color.clear
                            .frame(width: displayWidth, height: layout.height)
                    }
                }
            }
        }
    }

    private func isVisible(_ layout: PostImageSlicer.SliceLayout) -> Bool {
        guard let window = visibility.window else { return true }
        return layout.top <= window.upperBound && layout.top + layout.height >= window.lowerBound
    }

    private func placeholder(
        title: String,
        systemImage: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.callout)
            .foregroundStyle(theme.accentColor)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(minWidth: 132, minHeight: Self.deferredHeight)
            .background(theme.accentColor.opacity(0.08), in: .rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(theme.accentColor.opacity(0.45), style: .init(dash: [4, 3]))
            }
        }
        .buttonStyle(.plain)
    }
}

/// 一张图切出来的一段。
struct PostImageSlice: Identifiable {
    let id: Int
    let image: NSImage
    /// 这一段在整张位图里占的像素行，显示高度按它等比例算。
    let pixelRange: Range<Int>
}

/// 把很高的位图横着切成段。
///
/// 一个 `Image` 就是一个和它一样高的图层，Core Animation 要为整张备下绘制缓冲，
/// 而不管当下看得见多少。切段之后每段各是一层，视口外的段只画 `Color.clear`，
/// 不带位图内容也就不占绘制缓冲 —— 1080×16000 的长截图实测从 206 MB 降到 1 MB。
enum PostImageSlicer {
    /// 一段最多这么高。取一屏左右：再小只会徒增层数，再大就退回原来的问题。
    static let maximumSlicePixels = 1600

    static func slices(of cgImage: CGImage) -> [PostImageSlice] {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return [] }
        let count = max(1, Int((Double(height) / Double(maximumSlicePixels)).rounded(.up)))
        guard count > 1 else {
            return [PostImageSlice(
                id: 0,
                image: NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: width, height: height)
                ),
                pixelRange: 0..<height
            )]
        }

        var result: [PostImageSlice] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            // 边界按比例取整，相邻两段共用同一条边，整体严丝合缝地铺满原图。
            let top = height * index / count
            let bottom = height * (index + 1) / count
            guard bottom > top else { continue }
            // `CGImage` 的坐标原点在左上角，`top` 就是从上往下数的像素行。
            guard let piece = cgImage.cropping(to: CGRect(
                x: 0,
                y: top,
                width: width,
                height: bottom - top
            )) else { continue }
            result.append(PostImageSlice(
                id: index,
                image: NSImage(
                    cgImage: piece,
                    size: NSSize(width: width, height: bottom - top)
                ),
                pixelRange: top..<bottom
            ))
        }
        return result
    }

    /// 一段画在哪、画多高。边界按比例取整，相邻两段共用同一条边，
    /// 各段加起来正好是整张的高度，不会因为逐段取整攒出几点误差把版面顶歪。
    struct SliceLayout: Equatable {
        let top: CGFloat
        let height: CGFloat
    }

    static func layout(
        of slice: PostImageSlice,
        totalHeight: CGFloat,
        pixelHeight: Int
    ) -> SliceLayout {
        guard pixelHeight > 0 else { return SliceLayout(top: 0, height: 0) }
        let top = (totalHeight * CGFloat(slice.pixelRange.lowerBound) / CGFloat(pixelHeight))
            .rounded()
        let bottom = (totalHeight * CGFloat(slice.pixelRange.upperBound) / CGFloat(pixelHeight))
            .rounded()
        return SliceLayout(top: top, height: max(1, bottom - top))
    }

    static func displayHeight(
        of slice: PostImageSlice,
        totalHeight: CGFloat,
        pixelHeight: Int
    ) -> CGFloat {
        layout(of: slice, totalHeight: totalHeight, pixelHeight: pixelHeight).height
    }
}
