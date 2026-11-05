import Foundation

/// 应用支持的论坛站点。
///
/// 刻意不给 `default` 分支：加站点时编译器会把每一处需要补分支的地方一次指出来，
/// 不必靠人去搜。
enum ForumSite: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case nga
    case nodeseek
    case v2ex
    case linuxdo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nga: "NGA"
        case .nodeseek: "NodeSeek"
        case .v2ex: "V2EX"
        // 站点自己的写法：页面标题、Logo 都是全大写加一个空格。
        case .linuxdo: "LINUX DO"
        }
    }

    /// 侧栏和站点列表上的图标。
    var systemImage: String {
        switch self {
        case .nga: "flame"
        case .nodeseek: "cube"
        // 站点的图标就是一个方块里的 V。SF Symbols 里没有它的字样，
        // `v.circle` 是最接近的一个，也和另外两个站分得开。
        case .v2ex: "v.circle"
        // 站点的吉祥物是一只企鹅，SF Symbols 里没有；终端提示符和「Linux」最贴，也和另外三个分得开。
        case .linuxdo: "apple.terminal"
        }
    }

    var descriptor: ForumSiteDescriptor {
        switch self {
        case .nga: .nga
        case .nodeseek: .nodeseek
        case .v2ex: .v2ex
        case .linuxdo: .linuxdo
        }
    }
}
