import SwiftUI

/// 两条搜索栏（全站搜索面板、版面内搜索）共用的排版尺寸。
///
/// 原先两处各写各的：控件间距 10 对 8、两行之间 10 对 7、外边距 16 对 8、
/// 档位选择器的最小宽度 180 对 155。同一个东西在两个地方长得不一样，
/// 而且都比需要的松。数值收到这里，改一次两边一起动，也不会再各自漂移。
enum ForumSearchBarMetrics {
    /// 同一行里输入框、档位、按钮之间。
    static let controlSpacing: CGFloat = 8
    /// 输入行和下面那行「范围：…」之间。
    static let rowSpacing: CGFloat = 5
    /// 全站搜索面板的左缩进。
    ///
    /// 这个数不是挑出来的，是量出来的：版面里那条搜索栏在 `List` 里，系统自己又给行
    /// 加了一层边距（实测左 29pt），所以它天然躲开了侧栏浮层伸进内容栏的那 22pt。
    /// 全站面板是裸 `VStack`，没人替它加，得自己补齐 —— 补到和版面那条同一条竖线上。
    ///
    /// 实测（内容栏原点 x≈1993.5）：版面那条的输入框左边缘在 x=2032.5，
    /// 即缩进 39pt = 行内留白 10 + List 的 29。
    static let panelLeadingPadding: CGFloat = rowHorizontalPadding + 29

    /// 全站搜索面板的右缩进。
    ///
    /// 右边比左边还要多让一些，原因有两个：分栏拖拽条压在搜索按钮上（点上去会被当成
    /// **拖动栏宽**，按钮一声不吭地不响应），以及 List 给滚动条留的空档。
    /// 同样按版面那条量：它的搜索按钮右缘在 x=2396.5，距内容栏右缘（x≈2450.5）54pt。
    static let panelTrailingPadding: CGFloat = rowHorizontalPadding + 44

    /// 版面内搜索的左右留白。它是列表里的一行，跟着相邻行的边距走。
    static let rowHorizontalPadding: CGFloat = 10
    /// 上下留白。
    ///
    /// 比左右松一点：这一行离内容栏顶上的工具栏很近，收得太紧时按钮会贴到
    /// 工具栏和拖拽条交界的那个角上。
    static let verticalPadding: CGFloat = 12
    /// 档位选择器的最小宽度。
    ///
    /// 给一个固定值而不是让它贴着内容：换档位时标题长短不一（「用户」和
    /// 「话题标题和内容」差着一倍），贴着内容会让输入框跟着一起变宽变窄。
    /// 只有一档的站点根本不画这个控件，所以这个值不必迁就短标题。
    static let kindPickerMinWidth: CGFloat = 140
}
