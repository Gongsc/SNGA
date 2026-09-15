import SwiftUI

enum ContentColumnHeaderMetrics {
    /// 左右留白。和 `ForumSearchBar` 取同一个数 —— 那条栏是列表里的一行，
    /// 跟着相邻行的边距走，这条带子得和它落在同一条竖线上。
    static let horizontalPadding: CGFloat = 10
    /// 上下留白。
    ///
    /// 原先是 12，理由是「离工具栏太近，收紧了按钮会贴到工具栏和拖拽条交界那个
    /// 角上」。实测 8 还留得住那点余量，而标题和搜索栏之间原本空得过分 ——
    /// 工具栏自己已经占掉三十多点，再加 12 就是一段谁也不认识的空白。
    static let verticalPadding: CGFloat = 8
}

/// 中间那一栏每个板块顶上的那一条。
///
/// **为什么每个板块都得有。** 板块的标题画在窗口工具栏上（`RootView` 的
/// `browserModuleTitle`），背后是透明的 —— 那颗标题刻意关掉了工具栏的共用背板
/// （`.sharedBackgroundVisibility(.hidden)`），否则一行 `.title2` 粗体会被套进一枚
/// 玻璃胶囊里，和这个满屏主题色的应用对不上。代价是标题底下没有底：板块里要是直接
/// 摆一个铺满整栏的滚动视图，往上滚的内容就从标题底下穿过去，两层字叠在一起。
///
/// 「全部版面」一直没这毛病，不是因为它特殊，是因为它顶上正好压着一条不滚的搜索栏，
/// 滚动区从那条线以下才开始。这个视图把那套结构收成一份：一条**不滚**的、上主题底色
/// 的带子，末尾一道分隔线，用 `.safeAreaInset(edge: .top)` 扣在板块顶上。带子里放不放
/// 控件都行 —— 没有控件的板块（用户中心、论坛消息）拿到的就是一条纯底色的窄带，
/// 作用只有一个：把标题和底下滚动的内容隔开。
///
/// 尺寸只有这一份，别在各板块里另写一套。上一轮的教训摆在 `ForumSearchBar` 的注释里：
/// 同一条栏在两个页面上各写各的，间距、边距、选择器宽度四处都差着几点。
struct ContentColumnHeader<Content: View>: View {
    @Environment(\.sngaTheme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, ContentColumnHeaderMetrics.horizontalPadding)
                .padding(.vertical, ContentColumnHeaderMetrics.verticalPadding)

            Divider()
        }
        // 主题底色，不是 `.regularMaterial`：这条带子是内容的一部分，不是浮在内容
        // 之上的层。材质在午夜蓝和 NGA 暖金下会透出一块发灰的方片，和整栏对不上。
        .background(theme.backgroundColor)
    }
}

extension View {
    /// 给板块扣上那条带子。放控件的板块把控件传进来，没有控件的传空。
    func contentColumnHeader<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            ContentColumnHeader(content: content)
        }
    }

    /// 没有控件的板块：只要那道把标题和内容隔开的线。
    func contentColumnHeader() -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            ContentColumnHeader { Color.clear.frame(height: 0) }
        }
    }
}

/// 带子里那个「输入即筛选」的输入框。
///
/// 全部版面和浏览历史各有一个，原先一个是自己用 `theme.surfaceColor` 加圆角描边
/// 拼出来的盒子（高 34、圆角 8），另一个是系统的 `.roundedBorder`，两处并排看一眼
/// 就知道不是一套。统一取 `.roundedBorder` —— `ForumSearchBar` 里那个搜索框用的
/// 正是它，三处这才真的一样，而不是「看着差不多」。
struct ContentColumnFilterField: View {
    let prompt: String
    let accessibilityIdentifier: String
    @Binding var text: String

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.roundedBorder)
            // 宽度跟着容器走，不跟着内容走：从空到满、筛到筛不出，它都不该动。
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}
