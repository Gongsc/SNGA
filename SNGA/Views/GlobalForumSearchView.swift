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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                queryField
                kindPicker
                searchButton
            }

            HStack(spacing: 6) {
                Label("范围：全部版面", systemImage: "square.grid.2x2")
                    .foregroundStyle(.secondary)
                if isUserSearch {
                    Text("输入用户 ID 或用户名；数字用户名请在前面加“\\”。")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(16)
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
            : ForumSearchKind.currentForumKinds
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
        .frame(minWidth: 180)
        .accessibilityLabel("搜索类型")
        .accessibilityIdentifier("global-search-kind")
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
                Label("搜索 NGA 论坛", systemImage: "magnifyingglass")
            } description: {
                Text("可搜索话题、版面、版主和用户发布的内容。")
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
