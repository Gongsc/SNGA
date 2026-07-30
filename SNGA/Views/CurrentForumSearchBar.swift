import SwiftUI

struct CurrentForumSearchBar: View {
    @Binding var query: String
    @Binding var kind: ForumSearchKind
    let isSearching: Bool
    let isActive: Bool
    let search: () -> Void
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                queryField
                kindPicker
                actionButtons
            }

            Label("范围：当前版面", systemImage: "rectangle.inset.filled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
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

    private var kindPicker: some View {
        Picker("搜索类型", selection: $kind) {
            ForEach(ForumSearchKind.currentForumKinds) { searchKind in
                Text(searchKind.title).tag(searchKind)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(minWidth: 155)
        .accessibilityLabel("搜索类型")
        .accessibilityIdentifier("current-forum-search-kind")
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

    private var canSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !isSearching
    }

    private func performSearch() {
        guard canSearch else { return }
        search()
    }
}
