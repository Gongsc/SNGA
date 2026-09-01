import SwiftUI

extension View {
    /// 版面列表和搜索结果共用的一行话题的样式。
    ///
    /// 原先只有版面列表写全了，搜索结果只抄走了 `listRowInsets`，剩下三个漏了 ——
    /// 于是同样的一行话题在两个地方长得不一样：搜索结果里分隔线的起点由 SwiftUI
    /// 自己猜，猜到了右边那块回复数和日期上，画出来只剩右半截。
    ///
    /// 两条参考线必须成对给：只给一条，另一端仍然是猜的。
    /// 补偿两个列表容器默认缩进的差额。
    ///
    /// 版面列表和搜索结果是两个各自配置的 `List`，同样的行边距落在屏幕上并不在同一条
    /// 竖线上：实测搜索结果的行比版面列表靠左 14pt、靠右 28pt（右边那份多出来的多半是
    /// 滚动条的空档），多出来的部分正好伸到详情栏底下，日期被裁掉半截。
    ///
    /// 左右不是同一个数，所以分开给。这两个值只能靠量，`testSearchBarsAndResultRowsLineUpWithTheTopicList`
    /// 那条 UI 用例盯着两个列表的行对不对得齐 —— 系统哪天改了默认边距，它会先叫。
    func forumTopicListRow(
        leadingCompensation: CGFloat = 0,
        trailingCompensation: CGFloat = 0
    ) -> some View {
        self
            .listRowInsets(EdgeInsets(
                top: 2,
                leading: leadingCompensation,
                bottom: 2,
                trailing: 6 + trailingCompensation
            ))
            .listRowBackground(Color.clear)
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading] + 8
            }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                dimensions[.trailing] - 8
            }
    }
}
