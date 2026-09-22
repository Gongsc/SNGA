import SwiftUI

struct ForumSearchPaginationBar: View {
    let currentPage: Int
    let totalPages: Int
    let isLoading: Bool
    let refresh: () -> Void
    let navigate: (Int) -> Void

    var body: some View {
        // 加载指示器走栏的上边缘，理由和 `PaginationBar` 那条一样：栏里的东西
        // 全是 `fixedSize`，多出来一个就得有人让位，而让位的可能是整一列。
        BottomActionBar(loading: loading) {
            HStack(spacing: 10) {
                if totalPages > 1 {
                    Button("上一页", systemImage: "chevron.left") {
                        navigate(currentPage - 1)
                    }
                    .labelStyle(.iconOnly)
                    .help("搜索结果上一页")
                    .disabled(isLoading || currentPage <= 1)
                    .accessibilityIdentifier("search-previous-page")

                    Text("第 \(currentPage) / \(totalPages) 页")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button("下一页", systemImage: "chevron.right") {
                        navigate(currentPage + 1)
                    }
                    .labelStyle(.iconOnly)
                    .help("搜索结果下一页")
                    .disabled(isLoading || currentPage >= totalPages)
                    .accessibilityIdentifier("search-next-page")
                }

                Spacer()
                Button {
                    refresh()
                } label: {
                    Label("刷新搜索结果", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("刷新搜索结果")
                .disabled(isLoading)
                .accessibilityIdentifier("global-search-refresh")
            }
        }
    }

    private var loading: BottomActionBarLoading? {
        guard isLoading else { return nil }
        return BottomActionBarLoading(
            accessibilityLabel: "正在加载搜索结果",
            accessibilityIdentifier: "global-search-loading-indicator"
        )
    }
}
