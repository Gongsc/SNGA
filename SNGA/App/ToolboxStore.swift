import Foundation
import Observation

/// 小工具的状态：看的是哪一条资讯源，以及一个用来触发重新拉取的计数。
///
/// 小工具读的是 60s 开放接口，不需要账号，也不属于任何论坛。因此这里刻意不持有
/// `AppSession` —— 它和论坛的四个 store 是平级的，只是恰好住在同一个窗口里。
/// 论坛那边整体重构时，本类型不应该被牵连。
@MainActor
@Observable
final class ToolboxStore {
    var selectedFeed: ToolboxFeed = .worldBriefing

    /// 每次刷新自增。视图把它拼进 `.task(id:)`，用来在同一条资讯源上重新发起请求。
    private(set) var refreshRevision = 0

    func refresh() {
        refreshRevision &+= 1
    }
}
