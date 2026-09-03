import SwiftUI

/// 搜索栏：全站搜索面板和版面内搜索共用这一个。
///
/// 两处曾各写一份长得几乎一样的 `VStack`，于是同一条栏在两个页面上宽出十几点 ——
/// 相同的代码抄两遍，抄的人以为一样，SwiftUI 不以为。措辞、档位、标识符按参数给，
/// 排版只有这一份。
struct ForumSearchBar: View {
    /// 排版尺寸。
    ///
    /// 曾经是一个单独的 `ForumSearchBarMetrics`，因为那时有两条各写各的栏：控件间距
    /// 10 对 8、两行之间 10 对 7、外边距 16 对 8、档位选择器最小宽度 180 对 155 ——
    /// 同一个东西在两个地方长得不一样。栏并成一条之后，这些数没有第二份可漂移了，
    /// 收回它自己身上。
    ///
    /// 这里也没有「全站面板专用」的左右留白了。曾经有过一对按屏幕量出来的数
    /// （左 10+29、右 10+44），量的是「侧栏浮层伸进内容栏」那个状态；那个状态
    /// 并不总在 —— 内容栏的安全区什么时候把列表往里推、什么时候不推，取决于窗口和
    /// 分栏，于是同一份常量在另一半时间里整体偏出去二十多点。对齐靠的是两处用同一种
    /// 容器（都是 `List` 里的一行），不是靠数值凑。
    private enum Metrics {
        /// 同一行里输入框、档位、按钮之间。
        static let controlSpacing: CGFloat = 8
        /// 输入行和下面那行「范围：…」之间。
        static let rowSpacing: CGFloat = 5
        /// 左右留白。它是列表里的一行，跟着相邻行的边距走。
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

    @Environment(\.forumSiteDescriptor) private var siteDescriptor
    /// 可访问性标识符的前缀，`-field` / `-kind` / `-submit` / `-clear` 接在后面。
    let identifierPrefix: String
    /// 输入框念给旁白听的名字：两处搜的范围不同，这句话也不同。
    let fieldAccessibilityLabel: String
    /// 「范围：」后面那个词，各站各页自己说。
    let scopeSubject: String
    let scopeSystemImage: String
    /// 只有全站面板的用户搜索要多说一句怎么输入。
    var hint: String?
    let kinds: [ForumSearchKind]
    @Binding var query: String
    @Binding var kind: ForumSearchKind
    let isSearching: Bool
    let search: () -> Void
    /// 给了才画「清除」。版面内搜索用它退回原来的话题列表，全站面板没有可退的。
    var clear: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            HStack(spacing: Metrics.controlSpacing) {
                queryField
                // 只有一档时不画选择器：一个点开只有一个选项的菜单占着 140pt，
                // 却什么也选不了。搜的是什么改由下面那行「范围」说。
                if kinds.count > 1 {
                    kindPicker
                }
                actionButtons
            }

            HStack(spacing: 6) {
                Label(scopeTitle, systemImage: scopeSystemImage)
                    .foregroundStyle(.secondary)
                if let hint {
                    Text(hint)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, Metrics.rowHorizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var queryField: some View {
        TextField(kind.prompt, text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
            .onSubmit(performSearch)
            .accessibilityLabel(fieldAccessibilityLabel)
            .accessibilityIdentifier("\(identifierPrefix)-field")
    }

    private var kindPicker: some View {
        Picker("搜索类型", selection: $kind) {
            ForEach(kinds) { searchKind in
                Text(siteDescriptor.searchKindTitle(searchKind)).tag(searchKind)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(minWidth: Metrics.kindPickerMinWidth)
        .accessibilityLabel("搜索类型")
        .accessibilityIdentifier("\(identifierPrefix)-kind")
        // 换站之后选中的档位可能已经不在列表里了（NGA 上选了「标题和内容」再切到
        // NodeSeek）。Picker 遇到不在列表里的选中值会显示空白，且照样把它发出去 ——
        // 于是搜索以 unsupported 报错收场。
        .onChange(of: kinds, initial: true) { _, newKinds in
            guard !newKinds.contains(kind), let fallback = newKinds.first else { return }
            kind = fallback
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("搜索", systemImage: "magnifyingglass", action: performSearch)
                .buttonStyle(.borderedProminent)
                .labelStyle(.iconOnly)
                .disabled(!canSearch)
                .accessibilityIdentifier("\(identifierPrefix)-submit")

            if let clear {
                Button("清除", systemImage: "xmark.circle", action: clear)
                    .accessibilityIdentifier("\(identifierPrefix)-clear")
            }
        }
    }

    /// 选择器画出来时就不必在这里重复档位名了。
    private var scopeTitle: String {
        guard kinds.count <= 1 else { return "范围：\(scopeSubject)" }
        return "范围：\(scopeSubject) · \(siteDescriptor.searchKindTitle(kind))"
    }

    private var canSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSearching
    }

    private func performSearch() {
        guard canSearch else { return }
        search()
    }
}
