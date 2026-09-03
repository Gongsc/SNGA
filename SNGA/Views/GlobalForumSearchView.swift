import SwiftUI

struct GlobalForumSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.forumSiteDescriptor) private var siteDescriptor
    @State private var query = ""
    @State private var kind = ForumSearchKind.topicSubject

    var body: some View {
        List {
            // 搜索栏是列表的第一行，和版面里那条是同一个视图 —— 不是「摆成一样」，是
            // 同一种容器里的同一行。上一版把它放在 `List` 外面的 `VStack` 里，两边留白
            // 只能靠量，量出来的数只在「侧栏浮层伸进内容栏」那个状态下成立；
            // 换个窗口状态，整条栏和整张结果列表就一起偏出去二十多点。
            ForumSearchBar(
                identifierPrefix: "global-search",
                fieldAccessibilityLabel: "论坛搜索关键词",
                scopeSubject: "全部版面",
                scopeSystemImage: "square.grid.2x2",
                hint: isUserSearch ? "输入用户 ID 或用户名；数字用户名请在前面加“\\”。" : nil,
                kinds: availableKinds,
                query: $query,
                kind: $kind,
                isSearching: model.isSearchingForum,
                search: performSearch
            )
            searchContent
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 0, for: .scrollContent)
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

    /// 站点不支持全站搜索时，只留下能在当前版面里做的那几种。
    private var availableKinds: [ForumSearchKind] {
        model.session.supports(.globalSearch)
            ? siteDescriptor.searchKinds
            : siteDescriptor.currentForumSearchKinds
    }

    @ViewBuilder
    private var searchContent: some View {
        if model.isSearchingForum,
           model.forumSearchPage == nil {
            stateRow {
                ProgressView("正在搜索论坛…")
                    .accessibilityIdentifier("global-search-loading")
            }
        } else if let errorMessage = model.forumSearchErrorMessage {
            stateRow {
                ContentUnavailableView {
                    Label("搜索失败", systemImage: "exclamationmark.magnifyingglass")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试", action: performSearch)
                        .disabled(!canSearch)
                }
            }
        } else if let page = model.forumSearchPage,
                  page.request.forumID == nil {
            if page.isEmpty {
                stateRow {
                    ContentUnavailableView.search(text: page.request.query)
                        .accessibilityIdentifier("global-search-empty")
                }
            } else {
                ForumSearchResultsRows(page: page)
            }
        } else {
            stateRow {
                ContentUnavailableView {
                    Label("搜索 \(siteDescriptor.displayName) 论坛", systemImage: "magnifyingglass")
                } description: {
                    Text(siteDescriptor.searchSummary)
                }
            }
        }
    }

    /// 空状态、出错、还在搜 —— 都是列表里的一行，和版面内搜索的写法一致。
    private func stateRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 220)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
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
