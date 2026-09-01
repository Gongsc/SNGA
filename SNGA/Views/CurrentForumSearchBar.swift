import SwiftUI

struct CurrentForumSearchBar: View {
    @Environment(\.forumSiteDescriptor) private var siteDescriptor
    @Binding var query: String
    @Binding var kind: ForumSearchKind
    let isSearching: Bool
    let isActive: Bool
    let search: () -> Void
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ForumSearchBarMetrics.rowSpacing) {
            HStack(spacing: ForumSearchBarMetrics.controlSpacing) {
                queryField
                // 只有一档时不画选择器：一个点开只有一个选项的菜单占着 140pt，
                // 却什么也选不了。搜的是什么改由下面那行「范围」说。
                if availableKinds.count > 1 {
                    kindPicker
                }
                actionButtons
            }

            Label(scopeTitle, systemImage: "rectangle.inset.filled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, ForumSearchBarMetrics.rowHorizontalPadding)
        .padding(.vertical, ForumSearchBarMetrics.verticalPadding)
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
            .accessibilityLabel("在当前版面搜索")
            .accessibilityIdentifier("current-forum-search-field")
    }

    /// 档位按站点给：NodeSeek 的搜索只匹配标题，摆出「话题标题和内容」是在许一个空头。
    private var availableKinds: [ForumSearchKind] {
        siteDescriptor.currentForumSearchKinds
    }

    private var kindPicker: some View {
        Picker("搜索类型", selection: $kind) {
            ForEach(availableKinds) { searchKind in
                Text(siteDescriptor.searchKindTitle(searchKind)).tag(searchKind)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(minWidth: ForumSearchBarMetrics.kindPickerMinWidth)
        .accessibilityLabel("搜索类型")
        .accessibilityIdentifier("current-forum-search-kind")
        // 换站之后选中的档位可能已经不在列表里了（NGA 上选了「标题和内容」再切到
        // NodeSeek）。Picker 遇到不在列表里的选中值会显示空白，且照样把它发出去。
        .onChange(of: availableKinds, initial: true) { _, kinds in
            guard !kinds.contains(kind), let fallback = kinds.first else { return }
            kind = fallback
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("搜索", systemImage: "magnifyingglass", action: performSearch)
                .buttonStyle(.borderedProminent)
                .labelStyle(.iconOnly)
                .disabled(!canSearch)
                .accessibilityIdentifier("current-forum-search-submit")

            if isActive {
                Button("清除", systemImage: "xmark.circle", action: clear)
                    .accessibilityIdentifier("current-forum-search-clear")
            }
        }
    }

    /// 选择器画出来时就不必在这里重复档位名了。
    private var scopeTitle: String {
        guard availableKinds.count <= 1 else { return "范围：当前版面" }
        return "范围：当前版面 · \(siteDescriptor.searchKindTitle(kind))"
    }

    private var canSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !isSearching
    }

    private func performSearch() {
        guard canSearch else { return }
        search()
    }
}
