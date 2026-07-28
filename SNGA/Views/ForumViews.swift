import SwiftUI

struct BottomActionBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BottomActionBarButton(configuration: configuration)
    }

    private struct BottomActionBarButton: View {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.sngaTheme) private var theme
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 4)
                .frame(minWidth: 26, minHeight: 26)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(borderColor)
                }
                .contentShape(.rect)
                .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.1), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }

        private var backgroundColor: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed {
                return theme.accentColor.opacity(0.25)
            }
            if isHovered {
                return theme.accentColor.opacity(0.14)
            }
            return .clear
        }

        private var borderColor: Color {
            guard isEnabled, isHovered || configuration.isPressed else { return .clear }
            return theme.accentColor.opacity(configuration.isPressed ? 0.55 : 0.32)
        }
    }
}

struct UserCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    let uid: Int64?

    var body: some View {
        if model.activeAccountID == nil {
            ContentUnavailableView {
                Label("欢迎使用 SNGA", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("添加 NGA 账号后即可浏览论坛。")
            } actions: {
                Button("登录 NGA") { model.showsLogin = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    profileHeader

                    if model.isDisplayingActiveAccount {
                        checkInContent
                    }

                    basicInformation
                    reputationContent
                    activityContent
                }
                .padding(24)
            }
            .navigationTitle("用户中心")
            .task(id: targetUID) {
                if let targetUID {
                    await model.ensureUserCenterLoaded(uid: targetUID)
                }
            }
        }
    }

    @ViewBuilder
    private var profileHeader: some View {
        if let profile {
            HStack(alignment: .center, spacing: 16) {
                AsyncImage(url: profile.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 72, height: 72)
                .clipShape(.circle)

                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.displayName)
                        .font(.largeTitle.bold())
                    Text("UID \(profile.uid)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if let group = profile.userGroup, !group.isEmpty {
                            Text(group)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                        if let title = profile.title, !title.isEmpty {
                            Text(title)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var checkInContent: some View {
        let status = model.activeAccountCheckInStatus
        if status.canCheckIn {
            Button {
                Task { await model.checkInActiveAccount() }
            } label: {
                checkInStatusCard(status)
            }
            .buttonStyle(.plain)
            .help("点击签到")
        } else {
            checkInStatusCard(status)
                .help(checkInTitle(for: status))
        }
    }

    private func checkInStatusCard(_ status: DailyCheckInStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: checkInIcon(for: status))
                .font(.title2)
                .foregroundStyle(checkInColor(for: status))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(checkInTitle(for: status))
                    .font(.headline)
                Text(checkInDetail(for: status))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer()
            if status == .checkingIn {
                ProgressView()
                    .controlSize(.small)
            } else if status.canCheckIn {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            checkInColor(for: status).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .contentShape(.rect)
    }

    private func checkInTitle(for status: DailyCheckInStatus) -> String {
        switch status {
        case .checkedIn: "今日已签到"
        case .notCheckedIn: "今日尚未签到"
        case .checkingIn: "正在签到…"
        case .failed: "签到失败"
        }
    }

    private func checkInDetail(for status: DailyCheckInStatus) -> String {
        switch status {
        case let .checkedIn(message): message
        case .notCheckedIn: "点击状态卡完成今日签到"
        case .checkingIn: "正在向 NGA 确认签到结果"
        case let .failed(message): "\(message)；点击重试"
        }
    }

    private func checkInIcon(for status: DailyCheckInStatus) -> String {
        switch status {
        case .checkedIn: "checkmark.seal.fill"
        case .notCheckedIn: "checkmark.seal"
        case .checkingIn: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func checkInColor(for status: DailyCheckInStatus) -> Color {
        switch status {
        case .checkedIn: .green
        case .notCheckedIn: theme.accentColor
        case .checkingIn: .secondary
        case .failed: .orange
        }
    }

    @ViewBuilder
    private var basicInformation: some View {
        if let profile {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("基础信息")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    ProfileField(title: "用户 ID", value: String(profile.uid))
                    ProfileField(title: "用户名", value: profile.displayName)
                    ProfileField(title: "用户组", value: profile.userGroup ?? "—")
                    ProfileField(title: "发帖数", value: profile.postCount.map(String.init) ?? "—")
                    ProfileField(title: "注册时间", value: formatted(profile.registeredAt))
                    ProfileField(title: "IP 属地", value: profile.location ?? "—")
                    if let honor = profile.honor, !honor.isEmpty {
                        ProfileField(title: "头衔", value: honor)
                    }
                    if let followers = profile.followerCount {
                        ProfileField(title: "被关注", value: String(followers))
                    }
                }
                .padding(16)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))

                if let signature = profile.signature, !signature.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("签名").font(.caption).foregroundStyle(.secondary)
                        Text(signature)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    @ViewBuilder
    private var reputationContent: some View {
        if let profile {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("声望")
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ReputationMetric(
                        title: "威望",
                        value: profile.reputation.map { String(format: "%.1f", $0) } ?? "—",
                        systemImage: "star.circle"
                    )
                    ReputationMetric(
                        title: "声望",
                        value: profile.fame.map(String.init) ?? "—",
                        systemImage: "medal"
                    )
                    ReputationMetric(
                        title: "N 币",
                        value: profile.money.map(String.init) ?? "—",
                        systemImage: "circle.hexagongrid"
                    )
                }
            }
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("发布记录")
            Picker(
                "发布记录",
                selection: Binding(
                    get: { model.userActivityKind },
                    set: { kind in
                        guard let targetUID else { return }
                        Task {
                            await model.loadUserActivities(uid: targetUID, kind: kind, page: 1)
                        }
                    }
                )
            ) {
                ForEach(UserActivityKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            if model.userActivities.isEmpty {
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ContentUnavailableView(
                        "暂无\(model.userActivityKind.title)",
                        systemImage: model.userActivityKind == .topics
                            ? "text.bubble"
                            : "arrowshape.turn.up.left"
                    )
                    .frame(maxWidth: .infinity, minHeight: 150)
                }
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(model.userActivities) { activity in
                        Button {
                            Task { await model.openUserActivity(activity) }
                        } label: {
                            UserActivityRow(activity: activity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                userActivityPagination
            }
        }
    }

    private var userActivityPagination: some View {
        HStack(spacing: 12) {
            Button("上一页", systemImage: "chevron.left") {
                navigateActivity(to: model.userActivityPage - 1)
            }
            .disabled(model.isLoading || model.userActivityPage <= 1)

            Text("第 \(model.userActivityPage) / \(model.userActivityTotalPages) 页")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Button("下一页", systemImage: "chevron.right") {
                navigateActivity(to: model.userActivityPage + 1)
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.isLoading || !model.userActivityHasMore)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private func navigateActivity(to page: Int) {
        guard let targetUID else { return }
        Task {
            await model.loadUserActivities(
                uid: targetUID,
                kind: model.userActivityKind,
                page: page
            )
        }
    }

    private var targetUID: Int64? {
        uid ?? model.activeAccount?.ngaUID
    }

    private var profile: Profile? {
        if let currentProfile = model.currentProfile,
           currentProfile.uid == targetUID {
            return currentProfile
        }
        guard let account = model.activeAccount,
              account.ngaUID == targetUID else {
            return nil
        }
        return Profile(
            uid: account.ngaUID,
            displayName: account.displayName,
            avatarURL: account.avatarURL
        )
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(
            .dateTime
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title3.bold())
    }
}

private struct ProfileField: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

private struct ReputationMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.monospacedDigit().bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct UserActivityRow: View {
    let activity: UserActivity
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                if let forumName = activity.forumName, !forumName.isEmpty {
                    Text(forumName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }
                Text(activity.subject)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let excerpt = activity.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if let postedAt = activity.postedAt {
                Text(
                    postedAt,
                    format: .dateTime
                        .year()
                        .month(.twoDigits)
                        .day(.twoDigits)
                        .hour(.twoDigits(amPM: .omitted))
                        .minute(.twoDigits)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .background(
            isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .onHover { isHovered = $0 }
    }
}

struct ForumDirectoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    @State private var collapsedCategories: Set<String> = []
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            directorySearchField

            Divider()

            Group {
                if model.forums.isEmpty && !model.isLoading {
                    ContentUnavailableView("没有可用版面", systemImage: "square.grid.2x2")
                } else if isSearching && filteredCategories.isEmpty {
                    ContentUnavailableView(
                        "未找到版面",
                        systemImage: "magnifyingglass",
                        description: Text("没有与“\(trimmedSearchText)”匹配的版面")
                    )
                    .accessibilityIdentifier("directory-search-empty")
                } else {
                    List {
                        ForEach(filteredCategories) { category in
                            Group {
                                if isSearching {
                                    categoryHeader(category)
                                } else {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.16)) {
                                            toggleCategory(category.id)
                                        }
                                    } label: {
                                        categoryHeader(category)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .listRowInsets(
                                EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
                            )
                            .accessibilityIdentifier("directory-category-\(category.id)")

                            if isSearching || !collapsedCategories.contains(category.id) {
                                ForEach(category.forums) { forum in
                                    Button {
                                        Task { await model.openForum(forum) }
                                    } label: {
                                        ForumDirectoryInteractiveRow(
                                            forum: forum,
                                            isFavorite: model.favorites.contains {
                                                $0.forum.id == forum.id && $0.state != .pendingRemove
                                            }
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .listRowInsets(
                                        EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
                                    )
                                    .listRowBackground(Color.clear)
                                    .accessibilityIdentifier(
                                        "directory-forum-\(forum.id.description)"
                                    )
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("全部版面")
        .task {
            if model.forums.isEmpty { await model.loadForums() }
        }
    }

    private var directorySearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("搜索版面名称或 ID", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("directory-search-field")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
                .accessibilityIdentifier("directory-search-clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            theme.surfaceColor,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedSearchText.isEmpty
    }

    private var filteredCategories: [ForumCategory] {
        ForumDirectorySearch.filter(model.forumCategories, query: searchText)
    }

    private func categoryHeader(_ category: ForumCategory) -> some View {
        HStack(spacing: 6) {
            Image(
                systemName: !isSearching && collapsedCategories.contains(category.id)
                    ? "chevron.right"
                    : "chevron.down"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 12)
            Text(category.name)
                .font(.headline)
            Spacer()
            Text("\(category.forums.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }

    private func toggleCategory(_ categoryID: String) {
        if collapsedCategories.contains(categoryID) {
            collapsedCategories.remove(categoryID)
        } else {
            collapsedCategories.insert(categoryID)
        }
    }
}

enum ForumDirectorySearch {
    static func filter(_ categories: [ForumCategory], query: String) -> [ForumCategory] {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return categories }

        return categories.compactMap { category in
            let matchingForums = category.forums.filter { forum in
                let searchableText = [
                    category.name,
                    forum.name,
                    forum.subtitle,
                    forum.category,
                    forum.id.queryName,
                    forum.id.description
                ]
                .compactMap { $0 }
                .joined(separator: " ")

                return terms.allSatisfy { term in
                    searchableText.range(
                        of: term,
                        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                        locale: .current
                    ) != nil
                }
            }
            guard !matchingForums.isEmpty else { return nil }
            return ForumCategory(
                id: category.id,
                name: category.name,
                forums: matchingForums
            )
        }
    }
}

private struct ForumDirectoryInteractiveRow: View {
    @Environment(\.sngaTheme) private var theme
    let forum: Forum
    let isFavorite: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: forum.iconURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(forum.name)
                if let subtitle = forum.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(theme.accentColor)
                    .accessibilityLabel("已收藏")
                    .accessibilityIdentifier("directory-forum-favorite-\(forum.id.description)")
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? theme.accentColor.opacity(0.14) : Color.clear)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

struct FavoritesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    @State private var editingFolder: TopicFavoriteFolder?
    @State private var showsCreateFolder = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.favoriteTopicFolders.isEmpty {
                folderBar
                Divider()
            }

            Group {
                if model.favoriteTopicFolders.isEmpty && !model.isLoading {
                    ContentUnavailableView {
                        Label("还没有收藏夹", systemImage: "folder")
                    } description: {
                        Text("新建一个收藏夹后，即可按目录整理论坛主题。")
                    } actions: {
                        Button("新建收藏夹") {
                            showsCreateFolder = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if model.favoriteTopics.isEmpty && !model.isLoading {
                ContentUnavailableView {
                    Label("收藏夹为空", systemImage: "star")
                } description: {
                        if let folder = model.selectedFavoriteTopicFolder {
                            Text("“\(folder.name)”中还没有主题。打开主题后可从底部星标菜单选择收藏目录。")
                        } else {
                            Text("打开主题后可从底部星标菜单选择收藏目录。")
                        }
                } actions: {
                    Button("浏览全部版面") {
                        model.sidebarSelection = .directory
                        Task { await model.loadForums() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                } else {
                    List {
                        ForEach(model.favoriteTopics) { topic in
                            HStack(spacing: 10) {
                                Button {
                                    Task { await model.openTopic(topic) }
                                } label: {
                                    TopicRow(topic: topic)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Button {
                                    remove(topic)
                                } label: {
                                    Label("从当前收藏夹移除", systemImage: "star.fill")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .help("从当前收藏夹移除《\(topic.subject)》")
                                .disabled(model.updatingFavoriteTopicIDs.contains(topic.id))
                                .accessibilityIdentifier(
                                    "favorite-topic-remove-\(topic.id.rawValue)"
                                )
                            }
                            .contextMenu {
                                Button("打开主题") {
                                    Task { await model.openTopic(topic) }
                                }
                                Button("从当前收藏夹移除", role: .destructive) {
                                    remove(topic)
                                }
                            }
                            .accessibilityIdentifier(
                                "favorite-topic-\(topic.id.rawValue)"
                            )
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        TopicListPaginationBar(
                            currentPage: model.favoriteTopicPage,
                            totalPages: model.favoriteTopicTotalPages,
                            isLoading: model.isLoading,
                            navigate: { page in
                                Task { await model.loadFavoriteTopics(page: page) }
                            }
                        ) {
                            Button {
                                Task {
                                    await model.loadFavoriteTopicFolders(force: true)
                                    await model.loadFavoriteTopics(page: model.favoriteTopicPage)
                                }
                            } label: {
                                Label("刷新收藏夹", systemImage: "arrow.clockwise")
                            }
                            .labelStyle(.iconOnly)
                            .help("刷新收藏目录与主题")
                            .disabled(model.isLoading)
                            .accessibilityIdentifier("favorite-topics-refresh")
                        }
                    }
                }
            }
        }
        .navigationTitle("收藏夹")
        .task {
            await model.loadFavoriteTopicFolders(force: true)
            await model.loadFavoriteTopics(page: model.favoriteTopicPage)
        }
        .sheet(isPresented: $showsCreateFolder) {
            FavoriteFolderEditorSheet(
                title: "新建收藏夹",
                initialName: "",
                initialIsPublic: false,
                initialIsDefault: model.favoriteTopicFolders.isEmpty,
                save: { name, isPublic, isDefault in
                    await model.createTopicFavoriteFolder(
                        name: name,
                        isPublic: isPublic,
                        isDefault: isDefault
                    )
                }
            )
        }
        .sheet(item: $editingFolder) { folder in
            FavoriteFolderEditorSheet(
                title: "修改收藏夹",
                initialName: folder.name,
                initialIsPublic: folder.isPublic,
                initialIsDefault: folder.isDefault,
                save: { name, isPublic, isDefault in
                    var updated = folder
                    updated.name = name
                    updated.isPublic = isPublic
                    updated.isDefault = isDefault
                    return await model.updateTopicFavoriteFolder(updated)
                },
                delete: {
                    await model.deleteTopicFavoriteFolder(folder)
                }
            )
        }
    }

    private var folderBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.sortedFavoriteTopicFolders) { folder in
                        Button {
                            Task { await model.selectFavoriteTopicFolder(folder.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: folder.isDefault ? "folder.fill" : "folder")
                                Text(folder.name)
                                    .lineLimit(1)
                                if folder.isDefault {
                                    Text("默认")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                Text("\(folder.topicCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .foregroundStyle(
                                model.selectedFavoriteTopicFolderID == folder.id
                                    ? theme.accentColor
                                    : Color.primary
                            )
                            .background(
                                model.selectedFavoriteTopicFolderID == folder.id
                                    ? theme.accentColor.opacity(0.14)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("favorite-folder-\(folder.id)")
                    }
                }
            }
            .scrollIndicators(.hidden)

            Divider()
                .frame(height: 22)

            Button {
                editingFolder = model.selectedFavoriteTopicFolder
            } label: {
                Label("修改收藏夹", systemImage: "pencil")
            }
            .labelStyle(.iconOnly)
            .help("修改名称、公开状态及默认收藏夹")
            .disabled(model.selectedFavoriteTopicFolder == nil)
            .accessibilityIdentifier("favorite-folder-edit")

            Button {
                showsCreateFolder = true
            } label: {
                Label("新建收藏夹", systemImage: "folder.badge.plus")
            }
            .labelStyle(.iconOnly)
            .help("新建收藏夹")
            .accessibilityIdentifier("favorite-folder-create")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func remove(_ topic: Topic) {
        guard let folder = model.selectedFavoriteTopicFolder else { return }
        Task {
            await model.setTopicFavorite(topic, in: folder, isFavorite: false)
        }
    }
}

private struct FavoriteFolderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let save: (String, Bool, Bool) async -> Bool
    let delete: (() async -> Bool)?

    @State private var name: String
    @State private var isPublic: Bool
    @State private var isDefault: Bool
    @State private var isWorking = false
    @State private var showsDeleteConfirmation = false

    init(
        title: String,
        initialName: String,
        initialIsPublic: Bool,
        initialIsDefault: Bool,
        save: @escaping (String, Bool, Bool) async -> Bool,
        delete: (() async -> Bool)? = nil
    ) {
        self.title = title
        self.save = save
        self.delete = delete
        _name = State(initialValue: initialName)
        _isPublic = State(initialValue: initialIsPublic)
        _isDefault = State(initialValue: initialIsDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.bold())

            TextField("收藏夹名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveChanges)

            VStack(alignment: .leading, spacing: 10) {
                Toggle("公开收藏夹", isOn: $isPublic)
                Text("公开后，其他用户可通过网页查看这个收藏夹。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("设为默认收藏夹", isOn: $isDefault)
                Text("从主题页快速收藏时，默认优先选中这个目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                if delete != nil {
                    Button("删除收藏夹", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                    .disabled(isWorking)
                }
                Spacer()
                Button("取消", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("保存") {
                    saveChanges()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || isWorking)
            }

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(22)
        .frame(width: 430)
        .confirmationDialog(
            "删除收藏夹及其中的所有收藏主题？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let delete else { return }
                isWorking = true
                Task {
                    if await delete() {
                        dismiss()
                    } else {
                        isWorking = false
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveChanges() {
        guard !trimmedName.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            if await save(trimmedName, isPublic, isDefault) {
                dismiss()
            } else {
                isWorking = false
            }
        }
    }
}

struct TopicListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme
    let forumID: ForumID
    var reservesSidebarToggleSpace = false
    @State private var isSubforumsExpanded = false
    private let topAnchor = "topic-list-top"
    private let hiddenSidebarTitleClearance: CGFloat = 140

    var body: some View {
        ScrollViewReader { proxy in
            List {
                forumTitleRow
                    .id(topAnchor)

                if !model.subforums.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    isSubforumsExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(
                                        systemName: isSubforumsExpanded
                                            ? "chevron.down"
                                            : "chevron.right"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 12)

                                    HStack(spacing: 5) {
                                        Image(systemName: "square.grid.3x3")
                                            .foregroundStyle(theme.accentColor)
                                        Text("子版面")
                                    }
                                    .font(.headline)
                                    Text("\(model.subforums.count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("已显示 \(includedSubforumCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("topic-list-subforums-toggle")

                            if isSubforumsExpanded {
                                HStack {
                                    Text("勾选后在当前主题列表中显示该子版面的主题")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button(allSubforumsIncluded ? "全部隐藏" : "全部显示") {
                                        model.setAllSubforumsIncluded(!allSubforumsIncluded)
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                }

                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 220), spacing: 8)],
                                    alignment: .leading,
                                    spacing: 8
                                ) {
                                    ForEach(model.subforums) { forum in
                                        SubforumTile(
                                            forum: forum,
                                            isIncluded: model.includedSubforumIDs.contains(forum.id)
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                            dimensions[.leading] + 8
                        }
                        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                            dimensions[.trailing] - 8
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 7, leading: 0, bottom: 7, trailing: 10))
                }

                if model.subforums.isEmpty {
                    topicRows
                } else {
                    topicListHeader
                    topicRows
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TopicListPaginationBar(
                    currentPage: model.topicPage,
                    totalPages: model.topicTotalPages,
                    isLoading: model.isLoading,
                    navigate: { page in
                        Task {
                            await model.loadTopicPage(forumID: forumID, page: page)
                            await Task.yield()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(topAnchor, anchor: .top)
                            }
                        }
                    }
                ) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(topAnchor, anchor: .top)
                        }
                    } label: {
                        Label("回到顶部", systemImage: "arrow.up.to.line")
                    }
                    .labelStyle(.iconOnly)
                    .help("回到主题列表顶部")
                    .accessibilityIdentifier("topic-list-scroll-to-top")

                    Button {
                        guard let forum = model.currentForum else { return }
                        Task { await model.toggleFavorite(forum) }
                    } label: {
                        Label(
                            model.isActiveForumFavorite ? "取消收藏" : "收藏版面",
                            systemImage: model.isActiveForumFavorite ? "star.fill" : "star"
                        )
                    }
                    .labelStyle(.iconOnly)
                    .help(model.isActiveForumFavorite ? "取消收藏当前版面" : "收藏当前版面")
                    .disabled(model.currentForum == nil)
                    .accessibilityIdentifier("forum-favorite")

                    Button {
                        Task {
                            await model.refreshTopicList()
                            await Task.yield()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(topAnchor, anchor: .top)
                            }
                        }
                    } label: {
                        if model.isRefreshingTopics {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "list.bullet.rectangle")
                        }
                    }
                    .accessibilityLabel(
                        model.isRefreshingTopics ? "正在刷新主题列表" : "刷新主题列表"
                    )
                    .help("刷新主题列表")
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("forum-refresh")
                }
            }
            .overlay(alignment: .top) {
                if model.isRefreshingTopics, model.selectedForumID == forumID {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在刷新主题列表…")
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.separator.opacity(0.5))
                    }
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("topic-list-refreshing")
                }
            }
            .animation(
                .easeInOut(duration: 0.18),
                value: model.isRefreshingTopics
            )
            .onChange(of: model.topicListScrollToTopRevision) {
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(topAnchor, anchor: .top)
                    }
                }
            }
        }
        .task(id: forumID) {
            if model.currentForum?.id != forumID || model.topics.isEmpty {
                await model.loadTopics(forumID: forumID, reset: true)
            }
        }
        .onChange(of: forumID) {
            isSubforumsExpanded = false
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var topicListHeader: some View {
        Text("主题")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Divider()
                    .padding(.horizontal, 8)
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private var forumTitleRow: some View {
        HStack(spacing: 10) {
            if let parentForum = model.parentForum {
                ForumTitleBackButton(
                    title: "返回上级版面 \(parentForum.name)",
                    accessibilityIdentifier: "forum-back-to-parent",
                    isDisabled: model.isLoading
                ) {
                    Task { await model.openParentForum() }
                }
            } else {
                ForumTitleBackButton(
                    title: "返回全部版面",
                    accessibilityIdentifier: "forum-back-to-directory"
                ) {
                    model.returnToForumDirectory()
                }
            }

            Text(model.currentForum?.name ?? "主题")
                .font(.title2.bold())
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(
            .leading,
            reservesSidebarToggleSpace ? hiddenSidebarTitleClearance : 0
        )
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .animation(.easeOut(duration: 0.16), value: reservesSidebarToggleSpace)
        .accessibilityIdentifier("topic-list-top")
    }

    @ViewBuilder
    private var topicRows: some View {
        ForEach(model.displayedTopics) { topic in
            Button {
                Task { await model.openTopic(topic) }
            } label: {
                TopicInteractiveRow(
                    topic: topic,
                    isSelected: model.selectedTopicID == topic.id
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 6))
            .listRowBackground(Color.clear)
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading] + 8
            }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                dimensions[.trailing] - 8
            }
            .accessibilityIdentifier("topic-\(topic.id.rawValue)")
        }
    }

    private var includedSubforumCount: Int {
        model.subforums.count { model.includedSubforumIDs.contains($0.id) }
    }

    private var allSubforumsIncluded: Bool {
        !model.subforums.isEmpty &&
            model.subforums.allSatisfy { model.includedSubforumIDs.contains($0.id) }
    }
}

private struct ForumTitleBackButton: View {
    @Environment(\.sngaTheme) private var theme
    let title: String
    let accessibilityIdentifier: String
    var isDisabled = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(isHovered ? theme.accentColor : Color.secondary)
                .background {
                    Circle()
                        .fill(
                            isHovered
                                ? theme.accentColor.opacity(0.16)
                                : Color.clear
                        )
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 && !isDisabled }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct TopicListPaginationBar<Actions: View>: View {
    let currentPage: Int
    let totalPages: Int
    let isLoading: Bool
    var navigate: (Int) -> Void
    let actions: Actions

    @State private var pageText = "1"

    init(
        currentPage: Int,
        totalPages: Int,
        isLoading: Bool,
        navigate: @escaping (Int) -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        self.currentPage = currentPage
        self.totalPages = totalPages
        self.isLoading = isLoading
        self.navigate = navigate
        self.actions = actions()
    }

    var body: some View {
        paginationContent
            .buttonStyle(BottomActionBarButtonStyle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider()
            }
            .onAppear {
                pageText = String(currentPage)
            }
            .onChange(of: currentPage) { _, newValue in
                pageText = String(newValue)
            }
            .onChange(of: totalPages) { _, newValue in
                if let value = Int(pageText), value > newValue {
                    pageText = String(newValue)
                }
            }
    }

    private var paginationContent: some View {
        HStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                paginationControls(isCompact: false)
                paginationControls(isCompact: true)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                actions
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func paginationControls(isCompact: Bool) -> some View {
        if totalPages > 1 {
            HStack(spacing: isCompact ? 3 : 6) {
                Button("首页", systemImage: "backward.end.fill") {
                    navigate(1)
                }
                .labelStyle(.iconOnly)
                .help("跳转到主题列表首页")
                .accessibilityIdentifier("topic-list-first-page")
                .disabled(isLoading || currentPage <= 1)

                Button("上一页", systemImage: "chevron.left") {
                    navigate(currentPage - 1)
                }
                .labelStyle(.iconOnly)
                .help("主题列表上一页")
                .accessibilityIdentifier("topic-list-previous-page")
                .disabled(isLoading || currentPage <= 1)

                TextField("页码", text: $pageText)
                    .frame(width: isCompact ? 44 : 54)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(performJump)
                    .accessibilityLabel("主题列表目标页码")
                    .accessibilityIdentifier("topic-list-page-field")

                if !isCompact {
                    Text("/ \(totalPages)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button("跳转", action: performJump)
                        .accessibilityIdentifier("topic-list-jump")
                        .disabled(isLoading || parsedPage == nil || parsedPage == currentPage)
                }

                Button("下一页", systemImage: "chevron.right") {
                    navigate(currentPage + 1)
                }
                .labelStyle(.iconOnly)
                .help("主题列表下一页")
                .accessibilityIdentifier("topic-list-next-page")
                .disabled(isLoading || currentPage >= totalPages)

                Button("尾页", systemImage: "forward.end.fill") {
                    navigate(totalPages)
                }
                .labelStyle(.iconOnly)
                .help("跳转到主题列表尾页")
                .accessibilityIdentifier("topic-list-last-page")
                .disabled(isLoading || currentPage >= totalPages)
            }
            .fixedSize()
        }
    }

    private var parsedPage: Int? {
        guard let value = Int(pageText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...totalPages).contains(value) else {
            return nil
        }
        return value
    }

    private func performJump() {
        guard let parsedPage, parsedPage != currentPage, !isLoading else {
            pageText = String(currentPage)
            return
        }
        navigate(parsedPage)
    }
}

private struct SubforumTile: View {
    @Environment(AppModel.self) private var model
    let forum: Forum
    let isIncluded: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.openSubforum(forum) }
            } label: {
                HStack(spacing: 9) {
                    AsyncImage(url: forum.iconURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: forum.id.isSubforum ? "text.document" : "bubble.left.and.bubble.right")
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(forum.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if let subtitle = forum.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Toggle(
                "在主版面主题列表中显示 \(forum.name)",
                isOn: Binding(
                    get: { isIncluded },
                    set: { model.setSubforumIncluded(forum.id, included: $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help(isIncluded ? "隐藏该子版面及其下属主题" : "显示该子版面及其下属主题")
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.5))
        }
        .onHover { isHovered = $0 }
    }
}

private struct TopicInteractiveRow: View {
    @Environment(\.sngaTheme) private var theme
    let topic: Topic
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        TopicRow(topic: topic)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var backgroundColor: Color {
        if isSelected {
            return theme.accentColor.opacity(0.18)
        }
        if isHovered {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }
}

private struct TopicRow: View {
    @Environment(\.sngaTheme) private var theme
    let topic: Topic

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if topic.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(theme.accentColor)
                }
                if topic.isLocked { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                if topic.mirroredForumID != nil {
                    Label("版面镜像", systemImage: "arrow.triangle.branch")
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(theme.accentColor)
                        .background(theme.accentColor.opacity(0.12), in: Capsule())
                } else if let sourceForumName = topic.sourceForumName, !sourceForumName.isEmpty {
                    Text(sourceForumName)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(theme.accentColor)
                        .background(theme.accentColor.opacity(0.12), in: Capsule())
                }
                Text(topic.subject)
                    .font(.body.weight(topic.isPinned ? .semibold : .regular))
                    .lineLimit(3)
            }
            HStack {
                if topic.mirroredForumID != nil {
                    Label("进入 \(topic.subject) 版面", systemImage: "arrow.right.circle")
                } else {
                    Text(topic.author.isEmpty ? "未知作者" : topic.author)
                }
                Spacer()
                if topic.mirroredForumID == nil {
                    Label("\(topic.replyCount)", systemImage: "bubble.left")
                }
                if topic.mirroredForumID == nil,
                   let date = topic.lastReplyAt ?? topic.publishedAt {
                    Text(
                        date,
                        format: .dateTime
                            .year()
                            .month(.twoDigits)
                            .day(.twoDigits)
                            .hour(.twoDigits(amPM: .omitted))
                            .minute(.twoDigits)
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
