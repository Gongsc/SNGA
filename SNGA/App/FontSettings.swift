import AppKit
import CoreText
import SwiftUI

/// 字体设置分的三段。
///
/// 分段的依据是「这三处的字是用来干不同的事的」：侧栏是导航标签，扫一眼就过；
/// 话题列表是一屏几十条标题，密度比字号重要；话题内容要一句一句读下去。一个
/// 全局倍率伺候不了这三件事 —— 把正文调到 17 的人多半不想让侧栏跟着撑开，
/// 把收藏夹挤成两行。
enum FontArea: String, CaseIterable, Identifiable, Sendable {
    case sidebar
    case topicList
    case threadContent
    case postAuthor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sidebar: "侧边栏"
        case .topicList: "话题列表"
        case .threadContent: "话题内容"
        case .postAuthor: "用户信息"
        }
    }

    var detail: String {
        switch self {
        case .sidebar: "账号、版面、收藏与最近访问"
        case .topicList: "话题标题、作者与回复数"
        case .threadContent: "楼层正文、签名与楼层号"
        case .postAuthor: "楼层头上那一栏：作者、级别、声望与发帖时间"
        }
    }

    var systemImage: String {
        switch self {
        case .sidebar: "sidebar.left"
        case .topicList: "list.bullet"
        case .threadContent: "text.alignleft"
        case .postAuthor: "person.text.rectangle"
        }
    }

    /// 预览里那一行样例。三处各写各的，样例和真东西长得不像就看不出调整的效果。
    var sampleText: String {
        switch self {
        case .sidebar: "综合讨论区 · 最近访问"
        case .topicList: "【讨论】这是一条话题标题 Topic 123"
        case .threadContent: "这是楼层正文的示例文字，Sample text 123。"
        case .postAuthor: "某位作者"
        }
    }

    /// 样例底下那行小字。每一段都有这么一行（侧栏的徽章、列表的作者与日期、
    /// 楼层的楼层号与设备），它跟着同一个比例缩放，光看正文那行看不出这一点。
    var sampleDetail: String {
        switch self {
        case .sidebar: "未读 3 · 待签到"
        case .topicList: "某位作者 · 回复 128 · 2026-09-11 12:38"
        case .threadContent: "#12 · 发自桌面端 · 签名"
        case .postAuthor: "级别: 镜花水月 · 声望: 0 (lv1) · 2026-09-11 12:38"
        }
    }

    /// 这一段的默认字号，同时也是各语义档位的缩放基准。
    ///
    /// 侧栏、话题列表和用户信息是 13 —— macOS 的 `.body` 就是 13 点，它们的主行
    /// （版面名、话题标题、作者名）本来就走这一档。话题内容是 14：楼层正文无论
    /// 走原生还是走 WebView，本来都是 14（见 `PostDocument` 的 `--snga-font-size`
    /// 和 `PostParagraphAttributedText`），写成 13 会让「默认值」和界面上实际的
    /// 大小对不上。
    var defaultSize: Double {
        switch self {
        case .sidebar, .topicList, .postAuthor: 13
        case .threadContent: 14
        }
    }

    var familyKey: String { "appearance.font.\(rawValue).family" }
    var sizeKey: String { "appearance.font.\(rawValue).size" }
}

enum FontSettings {
    /// 下限按「还读得出来」定，上限按「侧栏一行还塞得下一个版面名」定。
    static let allowedSizeRange: ClosedRange<Double> = 10...22

    /// 空字符串表示系统字体。用哨兵值而不是 `nil`，是因为 `@AppStorage` 存不了
    /// 可选字符串，而「没选过」和「选了空名字」本来也是同一回事。
    static let systemFamilyName = ""

    static func normalizedSize(
        _ value: Double,
        for area: FontArea = .threadContent
    ) -> Double {
        guard value.isFinite else { return area.defaultSize }
        return min(max(value.rounded(), allowedSizeRange.lowerBound), allowedSizeRange.upperBound)
    }

    /// 可选的字体家族。
    ///
    /// 只问一次：这一趟要把系统装的字体全过一遍，每次重绘都问会让选择器在打开的
    /// 那一下卡住。
    ///
    /// 走 CoreText 而不是 `NSFontManager.shared.availableFontFamilies`：后者是
    /// 主线程隔离的，而这张表要在 `Binding` 的取值闭包里用来校验存下来的名字，
    /// 那个闭包不带隔离。字体清单本身和线程没有关系，换个入口就够了。
    ///
    /// 以点开头的是系统内部字体（`.AppleSystemUIFont` 这类），它们不该出现在
    /// 菜单里 —— 选中了也只是绕一圈回到系统字体。
    static let availableFamilies: [String] = {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    /// 存下来的名字现在还认不认。
    ///
    /// 字体是可以被卸载的，而设置里存的只是一个名字。名字指向的东西不在了就当
    /// 没选过 —— 比在选择器里留一个选不中的空行、在正文里画一片方块都好。
    static func normalizedFamily(_ familyName: String) -> String {
        guard !familyName.isEmpty, availableFamilies.contains(familyName) else {
            return systemFamilyName
        }
        return familyName
    }
}

/// 一段区域解析好的字体。
///
/// 界面上的文字仍然按语义档位（正文、脚注、标题）写，这里只把每一档按
/// `size / area.defaultSize` 整体缩放 —— 换成给每个 `Text` 配一个绝对点数，
/// 主次关系就要在几十个调用点上各维护一遍，调大一号之后标题和正文一样大。
struct ScopedFontSet: Equatable, Sendable {
    let area: FontArea
    /// 空串表示系统字体。
    let familyName: String
    let size: Double

    init(area: FontArea, familyName: String = FontSettings.systemFamilyName, size: Double? = nil) {
        self.area = area
        self.familyName = familyName
        self.size = FontSettings.normalizedSize(size ?? area.defaultSize, for: area)
    }

    static func `default`(for area: FontArea) -> ScopedFontSet {
        ScopedFontSet(area: area)
    }

    var isDefault: Bool {
        familyName == FontSettings.systemFamilyName && size == area.defaultSize
    }

    var scale: Double { size / area.defaultSize }

    // MARK: - 语义档位

    var body: Font { font(.body) }
    var callout: Font { font(.callout) }
    var caption: Font { font(.caption) }
    var caption2: Font { font(.caption2) }
    var headline: Font { font(.headline, weight: .semibold) }
    var title2: Font { font(.title2) }
    var title3: Font { font(.title3) }

    func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        Font(nsFont(ofSize: pointSize(for: style), weight: NSFont.Weight(weight)))
    }

    /// 某一档缩放之后的点数。AppKit 那几条路（楼层正文、话题标题）要的是数字。
    func pointSize(for style: Font.TextStyle) -> CGFloat {
        CGFloat(Self.systemPointSize(for: style) * scale)
    }

    /// 楼层正文的点数。默认档下就是 14，和网页那份 `--snga-font-size` 同一个数。
    var postBodySize: CGFloat { CGFloat(size) }

    /// 签名档和引用抬头的点数：比正文小一号，默认档下是 12。
    var postSmallSize: CGFloat { CGFloat(Self.postSmallBaseSize * scale) }

    /// 按家族名造字体。
    ///
    /// 走 `NSFontDescriptor` 而不是 `NSFont(name:size:)`：设置里存的是**家族名**
    /// （「PingFang SC」），而 `NSFont(name:)` 要的是具体某一款的名字
    /// （「PingFangSC-Regular」），拿家族名去问多半得到 nil。描述符这条路认家族，
    /// 还能顺便把字重一起要了。
    ///
    /// 家族不存在（被卸载了）时回落系统字体，绝不返回 nil 让调用方各自兜底。
    func nsFont(ofSize pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard !familyName.isEmpty else {
            return .systemFont(ofSize: pointSize, weight: weight)
        }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: familyName,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        return NSFont(descriptor: descriptor, size: pointSize)
            ?? .systemFont(ofSize: pointSize, weight: weight)
    }

    /// 等宽的那一份（代码、终端输出）不跟着换家族 —— 用户挑的多半是正文字体，
    /// 拿它排代码会让对齐全塌。只跟着缩放走。
    func monospacedNSFont(ofSize pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: pointSize, weight: weight)
    }

    // MARK: - 网页那一侧

    /// 把设置写进楼层文档。
    ///
    /// 和主题走同一条路：`:root` 上留几个带初值的变量，这里按字符串替换。默认档
    /// 下三处替换都是原样换原样，文档逐字节不变 —— 没改过设置的用户不该因为多了
    /// 这个功能而看到任何区别，`FontSettingsTests` 盯着这一条。
    func applying(to html: String) -> String {
        guard !isDefault else { return html }
        return html
            .replacingOccurrences(
                of: PostDocument.webFontSizeDeclaration,
                with: "--snga-font-size:\(Self.css(postBodySize))px"
            )
            .replacingOccurrences(
                of: PostDocument.webSmallFontSizeDeclaration,
                with: "--snga-font-small:\(Self.css(postSmallSize))px"
            )
            .replacingOccurrences(
                of: PostDocument.webFontFamilyDeclaration,
                with: "--snga-font-family:\(webFontFamily)"
            )
    }

    /// 用户挑的家族排在最前，系统那一串仍然跟在后面兜底 —— 这个家族缺的字
    /// （挑了一款只有拉丁字的字体时，整篇中文）由后面几档接住。
    private var webFontFamily: String {
        guard !familyName.isEmpty else { return PostDocument.webFontFamilyFallback }
        let quoted = familyName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(quoted)\",\(PostDocument.webFontFamilyFallback)"
    }

    /// 半点也要写出来：缩放之后 12 × 15/14 = 12.86，四舍五入成整数会让签名和正文
    /// 的差距在某些档位上整个消失。
    private static func css(_ value: CGFloat) -> String {
        let rounded = (Double(value) * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.2f", rounded)
    }

    // MARK: - 档位点数

    /// 签名档在默认档下的点数。`PostDocument.webSmallFontSizeDeclaration` 里是
    /// 同一个数：同一份签名可能走原生、也可能因为一张表格回退到 WebView，
    /// 两条路画出来必须一样大。
    static let postSmallBaseSize: Double = 12

    /// macOS 上各语义档位的点数，也就是 `NSFont.preferredFont(forTextStyle:)`
    /// 的取值。抄成一张表是为了缩放算得出、也测得了 —— `FontSettingsTests`
    /// 对着 AppKit 校这张表，哪天系统改了尺寸会红在那儿。
    static func systemPointSize(for style: Font.TextStyle) -> Double {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline: 13
        case .subheadline: 11
        case .body: 13
        case .callout: 12
        case .footnote: 10
        case .caption: 10
        case .caption2: 10
        @unknown default: 13
        }
    }
}

private extension NSFont.Weight {
    /// SwiftUI 的字重换算成 AppKit 的。两边的取值是一一对应的，只是类型不同。
    init(_ weight: Font.Weight) {
        switch weight {
        case .ultraLight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .regular: self = .regular
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        default: self = .regular
        }
    }
}

/// 三段字体的全集。和主题一样从应用顶上一次注入，视图按自己所在的那一段取。
///
/// 没有做成「每个区域自己读一遍 `@AppStorage`」：话题列表一屏几十行，那样等于
/// 给每一行都挂两个 UserDefaults 观察者。
struct ResolvedAppFonts: Equatable, Sendable {
    var sidebar: ScopedFontSet
    var topicList: ScopedFontSet
    var threadContent: ScopedFontSet
    /// 楼层头上那一栏。从话题内容里单拆出来，是因为这两处的诉求常常相反：
    /// 把正文调大是为了读得省力，而级别、声望、注册时间、威望是一排参考信息，
    /// 跟着正文一起长只会把头像那一格顶成半屏高。
    var postAuthor: ScopedFontSet

    static let `default` = ResolvedAppFonts(
        sidebar: .default(for: .sidebar),
        topicList: .default(for: .topicList),
        threadContent: .default(for: .threadContent),
        postAuthor: .default(for: .postAuthor)
    )

    var isDefault: Bool {
        FontArea.allCases.allSatisfy { self[$0].isDefault }
    }

    subscript(area: FontArea) -> ScopedFontSet {
        switch area {
        case .sidebar: sidebar
        case .topicList: topicList
        case .threadContent: threadContent
        case .postAuthor: postAuthor
        }
    }
}

extension EnvironmentValues {
    @Entry var sngaFonts: ResolvedAppFonts = .default
}
