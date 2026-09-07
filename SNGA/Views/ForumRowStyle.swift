import SwiftUI

extension View {
    /// 版面列表和搜索结果共用的一行话题的样式。
    ///
    /// 原先只有版面列表写全了，搜索结果只抄走了 `listRowInsets`，剩下三个漏了 ——
    /// 于是同样的一行话题在两个地方长得不一样：搜索结果里分隔线的起点由 SwiftUI
    /// 自己猜，猜到了右边那块回复数和日期上，画出来只剩右半截。
    ///
    /// 两条参考线必须成对给：只给一条，另一端仍然是猜的。
    func forumTopicListRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 6))
            .listRowBackground(Color.clear)
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading] + 8
            }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                dimensions[.trailing] - 8
            }
    }
}
