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
        /// 历史面板的圆角。
        static let historyCornerRadius: CGFloat = 8
        /// 历史面板每一行的上下留白。
        static let historyRowVerticalPadding: CGFloat = 5
        /// 历史面板左右的留白，和面板里的按钮共用。
        static let historyRowHorizontalPadding: CGFloat = 8
        /// 筛选面板里两行之间。
        static let filterRowSpacing: CGFloat = 8
        static let filterPanelPadding: CGFloat = 12
        static let filterCornerRadius: CGFloat = 10
        /// 作者输入框的宽度。给死值而不是让它撑满：撑满之后一个只填几个字的
        /// 用户名会横跨整块面板，右边空着一大片。
        static let filterFieldWidth: CGFloat = 220
        /// 排序那两个选择器的宽度。两个给同一个值，它们才并排对得齐。
        static let filterPickerWidth: CGFloat = 110
    }

    @Environment(\.forumSiteDescriptor) private var siteDescriptor
    @Environment(\.sngaTheme) private var theme
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
    /// 附加的筛选条件。哪几样画得出来由站点说（`searchFilters(for:)`），
    /// 一样都收不下的站点连这一栏都没有。
    @Binding var filters: ForumSearchFilters
    let isSearching: Bool
    /// 搜过的关键词。两条栏共用同一份 —— 见 `SearchHistoryStore`。
    let history: SearchHistoryStore
    let search: () -> Void
    /// 给了才画「清除」。版面内搜索用它退回原来的话题列表，全站面板没有可退的。
    var clear: (() -> Void)?

    @FocusState private var isQueryFieldFocused: Bool
    /// 面板开着没有。跟着焦点走，但不是焦点本身 —— Esc 收掉面板时焦点还在输入框里。
    @State private var isShowingHistory = false
    /// 筛选那一栏展开没有。默认收着：多数搜索用不到它。
    @State private var isShowingFilters = false

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
                    .foregroundStyle(theme.secondaryForegroundColor)
                if let hint {
                    Text(hint)
                        .foregroundStyle(theme.secondaryForegroundColor)
                }
                // 结果来自站外时说出来。写在这里而不是档位名里：那是个定宽的
                // 选择器，名字一长就截断成「主题正文（SoV2…」，反而谁也看不见。
                if let note = siteDescriptor.searchProviderNote(for: kind) {
                    Label(note, systemImage: "arrow.up.forward.app")
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .accessibilityIdentifier("\(identifierPrefix)-provider")
                }
                Spacer(minLength: 4)
                filterToggle
            }
            .font(.caption)
            .lineLimit(1)

            filterPanel
            historyPanel
        }
        // Esc 只收面板，不动焦点和已经输入的字 —— 那是 macOS 上「取消这层临时界面」
        // 的意思。
        .onExitCommand {
            isShowingHistory = false
        }
        // 换到一档收不下筛选的搜索时，把条件清掉。留着不画的话，用户看不见它，
        // 却仍然跟着请求发出去 —— 搜出来的结果和界面上写的对不上。
        .onChange(of: kind) { _, newKind in
            guard siteDescriptor.searchFilters(for: newKind).isEmpty else { return }
            filters = .none
            isShowingFilters = false
        }
        // 焦点离开时不立刻收面板：点面板里那一行的瞬间，输入框先把焦点交出去，
        // 这时候把面板拆掉，那一下点击就落到空处 —— 从用户那边看是「面板闪了一下，
        // 什么也没发生」。等一小会儿再看焦点是不是真的走了。
        .task(id: isQueryFieldFocused) {
            guard !isQueryFieldFocused else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !isQueryFieldFocused else { return }
            isShowingHistory = false
        }
        .padding(.horizontal, Metrics.rowHorizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// 「筛选」那颗按钮。站点这一档一样都收不下就整个不画。
    @ViewBuilder
    private var filterToggle: some View {
        if !siteDescriptor.searchFilters(for: kind).isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isShowingFilters.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isShowingFilters ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                    Text("筛选")
                    // 收着的时候也得让人知道有几条在生效，否则「怎么搜不到」
                    // 会变成一个查不出来的问题。
                    if activeFilterCount > 0 {
                        Text("\(activeFilterCount)")
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            // 强调色的淡底，跟着主题走。写死 `.tint` 在自定义主题下
                            // 会是另一个颜色。
                            .background(theme.accentSoftColor, in: Capsule())
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                activeFilterCount > 0 ? theme.accentColor : theme.secondaryForegroundColor
            )
            .accessibilityIdentifier("\(identifierPrefix)-filters-toggle")
        }
    }

    /// 有几条筛选在生效。排序不算 —— 它总是有个值，算进去的话徽章永远亮着。
    private var activeFilterCount: Int {
        var count = 0
        if filters.trimmedAuthor != nil { count += 1 }
        if filters.postedAfter != nil || filters.postedBefore != nil { count += 1 }
        if filters.sort != ForumSearchFilters.none.sort
            || filters.isAscending != ForumSearchFilters.none.isAscending {
            count += 1
        }
        return count
    }

    /// 筛选面板。
    ///
    /// 用 `Grid` 而不是一列 `LabeledContent`：后者每一行各管各的，标签宽度对不齐，
    /// 「只看作者」「发帖日期」「排序」三行的控件会各起各的头。两列到底，
    /// 标签列右对齐、控件列左对齐，日期那一行标签空着但格子还在，所以照样对得上。
    @ViewBuilder
    private var filterPanel: some View {
        let options = siteDescriptor.searchFilters(for: kind)
        if isShowingFilters, !options.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.filterRowSpacing) {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: Metrics.controlSpacing,
                    verticalSpacing: Metrics.filterRowSpacing
                ) {
                    if options.contains(.author) {
                        GridRow {
                            filterLabel("只看作者")
                            TextField("不限", text: $filters.author)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: Metrics.filterFieldWidth)
                                .onSubmit(performSearch)
                                .accessibilityIdentifier("\(identifierPrefix)-filter-author")
                        }
                    }
                    if options.contains(.dateRange) {
                        GridRow {
                            filterLabel("发帖日期")
                            Toggle("限定范围", isOn: dateRangeEnabled)
                                .toggleStyle(.checkbox)
                                .tint(theme.accentColor)
                                .accessibilityIdentifier("\(identifierPrefix)-filter-dates")
                        }
                        if let after = filters.postedAfter, let before = filters.postedBefore {
                            GridRow {
                                // 标签空着，但格子还在 —— 日期那一行才和上面对得齐。
                                Color.clear.frame(width: 1, height: 1)
                                HStack(spacing: Metrics.controlSpacing) {
                                    datePicker("从", selection: startDate(after, before))
                                    datePicker("到", selection: endDate(after, before))
                                }
                            }
                        }
                    }
                    if options.contains(.sortOrder) {
                        GridRow {
                            filterLabel("排序")
                            HStack(spacing: Metrics.controlSpacing) {
                                Picker("排序", selection: $filters.sort) {
                                    ForEach(ForumSearchSort.allCases) { sort in
                                        Text(sort.title).tag(sort)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: Metrics.filterPickerWidth)
                                .accessibilityLabel("排序方式")
                                .accessibilityIdentifier("\(identifierPrefix)-filter-sort")

                                Picker("顺序", selection: $filters.isAscending) {
                                    Text("降序").tag(false)
                                    Text("升序").tag(true)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: Metrics.filterPickerWidth)
                                .accessibilityLabel("排列顺序")
                                .accessibilityIdentifier("\(identifierPrefix)-filter-order")
                            }
                        }
                    }
                }

                Divider()

                HStack {
                    Spacer()
                    Button("清除筛选") { filters = .none }
                        .buttonStyle(.borderless)
                        .disabled(filters.isEmpty)
                        .accessibilityIdentifier("\(identifierPrefix)-filter-clear")
                }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(Metrics.filterPanelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 底色和描边都走主题。`.background.secondary` 是系统材质，
            // 自定义主题（午夜蓝、NGA 暖金）下它和周围对不上。
            .background(
                theme.surfaceColor,
                in: RoundedRectangle(cornerRadius: Metrics.filterCornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.filterCornerRadius)
                    .stroke(theme.separatorColor)
            }
            .accessibilityIdentifier("\(identifierPrefix)-filters")
        }
    }

    private func filterLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(theme.secondaryForegroundColor)
            .gridColumnAlignment(.trailing)
    }

    /// 日期用 `.field`：默认的 `.stepperField` 会在每个日期后面挂一对上下箭头，
    /// 两个日期就是四颗，把这一行撑得比别的行都高。
    private func datePicker(_ title: String, selection: Binding<Date>) -> some View {
        DatePicker(title, selection: selection, displayedComponents: .date)
            .datePickerStyle(.field)
            .accessibilityIdentifier("\(identifierPrefix)-filter-date-\(title)")
    }

    /// 起始日晚于结束日的话什么都搜不到，把另一头跟着推。
    private func startDate(_ after: Date, _ before: Date) -> Binding<Date> {
        Binding(
            get: { after },
            set: { newValue in
                filters.postedAfter = newValue
                if newValue > before { filters.postedBefore = newValue }
            }
        )
    }

    private func endDate(_ after: Date, _ before: Date) -> Binding<Date> {
        Binding(
            get: { before },
            set: { newValue in
                filters.postedBefore = newValue
                if newValue < after { filters.postedAfter = newValue }
            }
        )
    }

    /// 日期区间那个开关。
    ///
    /// 两端都是可选值，而 `DatePicker` 要一个非可选的绑定 —— 所以用一个开关决定
    /// 「限不限日期」，打开时给一段默认区间（最近一个月），关掉时两端一起清空。
    private var dateRangeEnabled: Binding<Bool> {
        Binding(
            get: { filters.postedAfter != nil || filters.postedBefore != nil },
            set: { isOn in
                guard isOn else {
                    filters.postedAfter = nil
                    filters.postedBefore = nil
                    return
                }
                let now = Date()
                filters.postedAfter = filters.postedAfter
                    ?? Calendar.current.date(byAdding: .month, value: -1, to: now)
                    ?? now
                filters.postedBefore = filters.postedBefore ?? now
            }
        )
    }

    private var queryField: some View {
        TextField(kind.prompt, text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
            .focused($isQueryFieldFocused)
            .onSubmit(performSearch)
            .onChange(of: isQueryFieldFocused) { _, isFocused in
                guard isFocused else { return }
                isShowingHistory = true
            }
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
        // 搜完把焦点交出去：面板是「点一下输入框就弹」的，焦点一直赖在框里，
        // 下一次点进来就没有「进入焦点」这件事，面板也就不再弹了。
        isShowingHistory = false
        isQueryFieldFocused = false
        search()
    }

    /// 面板里现在该列哪些词。
    ///
    /// 输入框空着就是全部（这是「点一下就弹」的那一下）；开始打字之后按输入过滤，
    /// 一条都不匹配时整块收掉 —— 打字时底下杵着一张对不上号的列表，比没有更烦。
    private var visibleHistory: [String] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.localizedCaseInsensitiveContains(keyword)
        }
    }

    @ViewBuilder
    private var historyPanel: some View {
        if isShowingHistory, !visibleHistory.isEmpty {
            // 面板是这一行自己的一部分，不是浮在列表上的另一层：`List` 的行会把
            // 越界的内容裁掉，而 `popover` 会把键盘焦点连同输入框一起端走 ——
            // 弹出来就打不了字了。这里让行自己长高，代价是底下的内容往下让一让。
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("搜索历史")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("全部清除") {
                        history.clear()
                        isShowingHistory = false
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityIdentifier("\(identifierPrefix)-history-clear-all")
                }
                .padding(.horizontal, Metrics.historyRowHorizontalPadding)
                .padding(.vertical, Metrics.historyRowVerticalPadding)

                Divider()

                // 不套 ScrollView：条数本来就有上限（默认 10，最多 30），
                // 而列表里再嵌一层滚动，滚轮该归谁全凭指针停在哪。
                ForEach(visibleHistory, id: \.self) { entry in
                    SearchHistoryEntryRow(
                        entry: entry,
                        identifierPrefix: identifierPrefix,
                        select: { select(entry) },
                        remove: { history.remove(entry) }
                    )
                }
            }
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: Metrics.historyCornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.historyCornerRadius)
                    .strokeBorder(.separator)
            )
            .accessibilityIdentifier("\(identifierPrefix)-history")
        }
    }

    /// 点历史里的一条：填进输入框并立刻搜。历史存的就是「下次点一下重搜一次」。
    private func select(_ entry: String) {
        query = entry
        performSearch()
    }

    /// 历史里的一行：整行是「重搜这个词」，行尾的叉是「只删这一条」。
    ///
    /// 两个按钮是并排的兄弟，不是嵌套 —— 按钮套按钮在 macOS 上里面那个点不动。
    /// 放在这里面是为了和上面那些控件共用同一份 `Metrics`：留白在两个地方各写
    /// 一遍，正是这条栏当年分裂成两条的起点。
    private struct SearchHistoryEntryRow: View {
        let entry: String
        let identifierPrefix: String
        let select: () -> Void
        let remove: () -> Void

        @State private var isHovering = false

        var body: some View {
            HStack(spacing: 4) {
                Button(action: select) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        Text(entry)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 整行可点，而不是只有那几个字：一行里最容易点中的是空白处。
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("重新搜索“\(entry)”")
                .accessibilityIdentifier("\(identifierPrefix)-history-entry-\(entry)")

                Button("删除", systemImage: "xmark", action: remove)
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("从搜索历史中删除“\(entry)”")
                    .accessibilityIdentifier("\(identifierPrefix)-history-delete-\(entry)")
            }
            .padding(.horizontal, Metrics.historyRowHorizontalPadding)
            .padding(.vertical, Metrics.historyRowVerticalPadding)
            .background(isHovering ? Color.primary.opacity(0.08) : .clear)
            .onHover { isHovering = $0 }
        }
    }
}
