import SwiftUI

struct GlobalForumSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.forumSiteDescriptor) private var siteDescriptor
    @State private var query = ""
    @State private var kind = ForumSearchKind.topicSubject

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            searchContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("搜索")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let page = model.forumSearchPage,
               page.request.forumID == nil {
                ForumSearchPaginationBar(
                    currentPage: page.page,
                    totalPages: page.totalPages,
                    isLoading: model.isSearchingForum,
                    refresh: {
                        Task {
                            await model.searchForum(
                                page.request,
                                page: page.page
                            )
                        }
                    }
                ) { targetPage in
                    Task { await model.loadForumSearchPage(targetPage) }
                }
            }
        }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: ForumSearchBarMetrics.rowSpacing) {
            HStack(spacing: ForumSearchBarMetrics.controlSpacing) {
                queryField
                // 只有一档时不画选择器：一个点开只有一个选项的菜单占着 140pt，
                // 却什么也选不了。搜的是什么改由下面那行「范围」说。
                if availableKinds.count > 1 {
                    kindPicker
                }
                searchButton
            }

            HStack(spacing: 6) {
                Label(scopeTitle, systemImage: "square.grid.2x2")
                    .foregroundStyle(.secondary)
                if isUserSearch {
                    Text("输入用户 ID 或用户名；数字用户名请在前面加“\\”。")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        // 左右不对称，而且和版面那条不是同一个数 —— 两条栏所处的容器不同，
        // 要的是**画面上对齐**，不是常量相等。见 `ForumSearchBarMetrics`。
        .padding(.leading, ForumSearchBarMetrics.panelLeadingPadding)
        .padding(.trailing, ForumSearchBarMetrics.panelTrailingPadding)
        .padding(.vertical, ForumSearchBarMetrics.verticalPadding)
    }

    /// 选择器画出来时就不必在这里重复档位名了。
    private var scopeTitle: String {
        guard availableKinds.count <= 1 else { return "范围：全部版面" }
        return "范围：全部版面 · \(siteDescriptor.searchKindTitle(kind))"
    }

    private var queryField: some View {
        TextField(kind.prompt, text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
            .onSubmit(performSearch)
            .accessibilityLabel("论坛搜索关键词")
            .accessibilityIdentifier("global-search-field")
    }

    /// 站点不支持全站搜索时，只留下能在当前版面里做的那几种。
    private var availableKinds: [ForumSearchKind] {
        model.session.supports(.globalSearch)
            ? siteDescriptor.searchKinds
            : siteDescriptor.currentForumSearchKinds
    }

    private var kindPicker: some View {
        Picker("搜索类型", selection: $kind) {
            ForEach(availableKinds) { searchKind in
                Label(
                    siteDescriptor.searchKindTitle(searchKind),
                    systemImage: searchKind.systemImage
                )
                    .tag(searchKind)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(minWidth: ForumSearchBarMetrics.kindPickerMinWidth)
        .accessibilityLabel("搜索类型")
        .accessibilityIdentifier("global-search-kind")
        // 换站之后选中的档位可能已经不在列表里了。Picker 遇到不在列表里的选中值会显示
        // 空白，且照样把它发出去 —— 于是搜索以 unsupported 报错收场。
        .onChange(of: availableKinds, initial: true) { _, kinds in
            guard !kinds.contains(kind), let fallback = kinds.first else { return }
            kind = fallback
        }
    }

    private var searchButton: some View {
        Button("搜索", systemImage: "magnifyingglass", action: performSearch)
            .buttonStyle(.borderedProminent)
            .labelStyle(.iconOnly)
            .disabled(!canSearch)
            .accessibilityIdentifier("global-search-submit")
    }

    @ViewBuilder
    private var searchContent: some View {
        if model.isSearchingForum,
           model.forumSearchPage == nil {
            ProgressView("正在搜索论坛…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("global-search-loading")
        } else if let errorMessage = model.forumSearchErrorMessage {
            ContentUnavailableView {
                Label("搜索失败", systemImage: "exclamationmark.magnifyingglass")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("重试", action: performSearch)
                    .disabled(!canSearch)
            }
        } else if let page = model.forumSearchPage,
                  page.request.forumID == nil {
            if page.isEmpty {
                ContentUnavailableView.search(text: page.request.query)
                    .accessibilityIdentifier("global-search-empty")
            } else {
                ForumSearchResultsView(page: page)
            }
        } else {
            ContentUnavailableView {
                Label("搜索 \(siteDescriptor.displayName) 论坛", systemImage: "magnifyingglass")
            } description: {
                Text(siteDescriptor.searchSummary)
            }
        }
    }

    private var canSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.isSearchingForum
    }

    private var isUserSearch: Bool {
        switch kind {
        case .user, .userTopics, .userContent: true
        case .topicSubject, .topicContent, .forum: false
        }
    }

    private func performSearch() {
        guard canSearch,
              let request = ForumSearchRequest(query: query, kind: kind) else {
            return
        }
        Task { await model.searchForum(request) }
    }
}
