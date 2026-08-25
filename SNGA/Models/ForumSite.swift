import Foundation

/// 应用支持的论坛站点。
///
/// 现在只有一个 case，所有 `switch` 都是穷尽的 —— 这是刻意的。加第二个站点时编译器
/// 会把每一处需要补分支的地方一次指出来，不必靠人去搜。
enum ForumSite: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case nga

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nga: "NGA"
        }
    }

    var descriptor: ForumSiteDescriptor {
        switch self {
        case .nga: .nga
        }
    }
}
