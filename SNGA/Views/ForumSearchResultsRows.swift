import SwiftUI

/// 全站搜索结果的那几种行。
///
/// 它只出行，不出容器：容器是 `GlobalForumSearchView` 那个 `List`，和版面话题列表
/// 是同一种。两个列表用同一个容器形状，行才会自然落在同一条竖线上 —— 之前这里
/// 自己开一个 `List`，两个容器的缩进不一样，只能靠量出来的补偿值去凑。
struct ForumSearchResultsRows: View {
    @Environment(AppModel.self) private var model
    let page: ForumSearchPage

    var body: some View {
        Group {
            ForEach(page.topics) { topic in
                Button {
                    Task { await model.openTopic(topic) }
                } label: {
                    TopicInteractiveRow(
                        topic: topic,
                        isSelected: model.thread.selectedTopicID == topic.id
                    )
                }
                .buttonStyle(.plain)
                .forumTopicListRow()
                .accessibilityIdentifier("search-topic-\(topic.id.rawValue)")
            }

            ForEach(page.forums) { forum in
                Button {
                    Task { await model.openForum(forum) }
                } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: forum.iconURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(forum.name)
                                .font(.headline)
                            if let subtitle = forum.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .forumTopicListRow()
                .accessibilityIdentifier("search-forum-\(forum.id.description)")
            }

            if page.request.kind == .user {
                ForEach(page.users, id: \.uid) { profile in
                    Button {
                        Task {
                            await model.openUserCenter(
                                uid: profile.uid,
                                fallbackName: profile.displayName,
                                fallbackAvatarURL: profile.avatarURL,
                                remembersOrigin: true
                            )
                        }
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: profile.avatarURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.crop.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 38, height: 38)
                            .clipShape(.circle)
                            .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.displayName)
                                    .font(.headline)
                                Text("UID \(profile.uid)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .forumTopicListRow()
                    .accessibilityIdentifier("search-user-\(profile.uid)")
                }
            }

            ForEach(page.activities) { activity in
                Button {
                    Task { await model.openForumSearchActivity(activity) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let forumName = activity.forumName, !forumName.isEmpty {
                                Text(forumName)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tint)
                            }
                            Text(activity.subject)
                                .font(.body)
                                .lineLimit(2)
                        }
                        if let excerpt = activity.excerpt, !excerpt.isEmpty {
                            Text(excerpt)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .forumTopicListRow()
                .accessibilityIdentifier("search-activity-\(activity.id)")
            }
        }
    }
}
