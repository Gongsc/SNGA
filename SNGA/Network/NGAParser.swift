import CoreFoundation
import Foundation
import SwiftSoup

struct ParsedHTMLForm: Sendable {
    var action: URL
    var fields: [String: String]
}

/// 编译一个正则的成本远高于用它匹配一次，而解析器里同一批 pattern 会在每个楼层、
/// 每一页上反复出现。这里按 pattern 与 options 缓存已编译的表达式；
/// `NSRegularExpression` 匹配本身是线程安全的，可以跨账号 actor 共享。
private final class CachedRegularExpressions: @unchecked Sendable {
    private struct Key: Hashable {
        let pattern: String
        let options: NSRegularExpression.Options.RawValue
    }

    static let shared = CachedRegularExpressions()

    /// 少数 pattern 由站点字段名拼出。正常取值有限，这里仍设上限兜底，
    /// 避免页面结构异变时缓存无限增长。
    private static let capacity = 256

    private let lock = NSLock()
    private var storage: [Key: NSRegularExpression] = [:]

    func expression(
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        let key = Key(pattern: pattern, options: options.rawValue)
        lock.lock()
        let cached = storage[key]
        lock.unlock()
        if let cached { return cached }

        guard let compiled = try? NSRegularExpression(
            pattern: pattern,
            options: options
        ) else {
            return nil
        }
        lock.lock()
        if storage.count >= Self.capacity { storage.removeAll(keepingCapacity: true) }
        storage[key] = compiled
        lock.unlock()
        return compiled
    }
}

struct NGAParser: Sendable {
    func profile(from response: NGAHTTPResponse, expectedUID: Int64) throws -> Profile {
        let text = try response.decodedString()
        if let root = jsonRoot(response.data) ?? jsonRoot(text) {
            try throwJSONErrorIfPresent(in: root)
            for dictionary in dictionaries(in: root) {
                let uid = int64(dictionary["uid"]) ?? int64(dictionary["id"])
                if uid == expectedUID,
                   let profile = profile(from: dictionary, expectedUID: expectedUID) {
                    return profile
                }
            }
        }

        let document = try SwiftSoup.parse(text, response.url.absoluteString)
        let title = try document.title().trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = title.components(separatedBy: ["-", "_"]).first?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty, candidate != "NGA" else {
            return Profile(uid: expectedUID, displayName: "NGA \(expectedUID)", avatarURL: nil)
        }
        return Profile(uid: expectedUID, displayName: candidate, avatarURL: nil)
    }

    func searchedProfile(from response: NGAHTTPResponse) throws -> Profile? {
        let text = try response.decodedString()
        guard let root = jsonRoot(response.data) ?? jsonRoot(text) else {
            throw NGAServiceError.unexpectedPage("未找到用户搜索数据")
        }
        if let dictionary = root as? [String: Any],
           let errorValue = dictionary["error"] ?? dictionary["__MESSAGE"] {
            let message = concise(flattenedText(errorValue))
            if message.contains("找不到用户") || message.contains("用户不存在") {
                return nil
            }
        }
        try throwJSONErrorIfPresent(in: root)
        return dictionaries(in: root).lazy.compactMap {
            profile(from: $0, expectedUID: nil)
        }.first
    }

    func forumSearchTopics(
        from response: NGAHTTPResponse,
        request: ForumSearchRequest,
        page: Int
    ) throws -> ForumSearchPage {
        let text = try response.decodedString()
        try throwStructuredErrorIfPresent(in: text)
        let topicValues = try structuredItemDictionaries(
            in: text,
            sectionName: "__T"
        )
        let fallbackForumID = request.forumID ?? ForumID(rawValue: 0)
        let topics = unique(topicValues.compactMap {
            parseTopic(from: $0, fallbackForumID: fallbackForumID)
        })
        let rowCount = structuredInteger(named: "__ROWS", in: text)
        let rowsPerPage = structuredInteger(named: "__T__ROWS_PAGE", in: text)
            ?? max(topics.count, 35)
        let totalPages = rowCount.map {
            max(1, Int(ceil(Double($0) / Double(max(1, rowsPerPage)))))
        } ?? max(1, page, topics.count >= rowsPerPage ? page + 1 : page)
        return ForumSearchPage(
            request: request,
            topics: topics,
            page: max(1, page),
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    func forumSearchResults(from response: NGAHTTPResponse) throws -> [Forum] {
        let text = try response.decodedString()
        try throwStructuredErrorIfPresent(in: text)
        let values = try structuredItemDictionaries(in: text)
        return unique(values.compactMap { forum(from: $0) })
    }

    func userActivities(
        from response: NGAHTTPResponse,
        uid: Int64,
        kind: UserActivityKind,
        page: Int
    ) throws -> UserActivityPage {
        let text = try response.decodedString()
        if let root = jsonRoot(response.data) ?? jsonRoot(text) {
            try throwJSONErrorIfPresent(in: root)
        }
        if text.contains("你必须登录") || text.contains("必须登录后") {
            throw NGAServiceError.requiresLogin
        }

        let document = try SwiftSoup.parse(text, response.url.absoluteString)
        let rows = try document.select("tr.topicrow")
        var activities: [UserActivity] = []
        for row in rows {
            guard let topicLink = try row.select(".c2 a.topic, a.topic").first(),
                  let target = absoluteURL(try topicLink.attr("href"), relativeTo: response.url),
                  let tid = queryInt64("tid", in: target) else {
                continue
            }
            let subject = try topicLink.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty else { continue }

            let boardLink = try row.select(".titleadd2 a[href*='fid='], .titleadd2 a").first()
            let forumID = try boardLink.flatMap {
                absoluteURL(try $0.attr("href"), relativeTo: response.url)
            }.flatMap { queryInt64("fid", in: $0) }.map(ForumID.init(rawValue:))
            let forumName = try boardLink?.text()
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]").union(.whitespacesAndNewlines))
            let dateElement = try row.select(".c3 .postdate, .postdate").first()
            let dateText: String?
            if let dateElement {
                let title = try dateElement.attr("title")
                dateText = title.isEmpty ? try dateElement.text() : title
            } else {
                dateText = nil
            }
            let postLink = try row.select("a[href*='pid=']").first()
            let postID = try postLink.flatMap {
                absoluteURL(try $0.attr("href"), relativeTo: response.url)
            }.flatMap { queryInt64("pid", in: $0) }.map(PostID.init(rawValue:))
            let excerpt: String?
            if kind == .replies,
               let content = try row.select(".c2 .postcontent, .postcontent").first() {
                let fragment = try SwiftSoup.parseBodyFragment(try content.html())
                for removable in try fragment.select(".quote, .block_txt, .userlink, .silver, img, script") {
                    try removable.remove()
                }
                let value = try fragment.text()
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                excerpt = value.isEmpty ? nil : value
            } else {
                excerpt = nil
            }
            let identity = [
                kind.rawValue,
                String(tid),
                postID.map { String($0.rawValue) } ?? "",
                excerpt ?? "",
                dateText ?? ""
            ].joined(separator: ":")
            activities.append(UserActivity(
                id: String(stableID(for: identity)),
                kind: kind,
                topicID: TopicID(rawValue: tid),
                postID: postID,
                forumID: forumID,
                forumName: forumName.flatMap { $0.isEmpty ? nil : $0 },
                subject: subject,
                excerpt: excerpt,
                postedAt: dateText.flatMap(ngaDate)
            ))
        }

        if activities.isEmpty, !rows.isEmpty {
            throw NGAServiceError.unexpectedPage("未能解析用户\(kind.title)列表")
        }
        if activities.isEmpty, rows.isEmpty {
            let pageTitle = try document.title()
            guard pageTitle.localizedCaseInsensitiveContains("NGA")
                    || text.contains("没有符合条件")
                    || text.contains("没有找到")
                    || text.contains("暂无") else {
                throw NGAServiceError.unexpectedPage("未找到用户\(kind.title)列表")
            }
        }

        let linkedPages = try document.select("a[href*='authorid='][href*='page=']").compactMap { link -> Int? in
            guard let target = absoluteURL(try link.attr("href"), relativeTo: response.url) else {
                return nil
            }
            return queryInt64("page", in: target).map(Int.init)
        }
        let hasNextLink = try document.select("a").contains { link in
            let title = (try? link.attr("title")) ?? ""
            let label = (try? link.text()) ?? ""
            return title.contains("下一页") || label.contains("下一页")
        }
        let totalPages = max(page, linkedPages.max() ?? 1, hasNextLink ? page + 1 : page)
        return UserActivityPage(
            kind: kind,
            activities: unique(activities),
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    func forums(from response: NGAHTTPResponse) throws -> [Forum] {
        if let root = jsonRoot(response.data) as? [String: Any] {
            if let code = int(root["code"]), code != 0 {
                let message = string(root["msg"]) ?? "版面目录请求失败（代码 \(code)）"
                if code == 5 || message.contains("登录") {
                    throw NGAServiceError.requiresLogin
                }
                throw NGAServiceError.restricted(message)
            }

            if let categories = root["result"] as? [Any] {
                let iconPrefix = string(root["forum_icon_pre"])
                var result: [Forum] = []
                for case let category as [String: Any] in categories {
                    let categoryName = string(category["name"])
                    guard let groups = category["groups"] as? [Any] else { continue }
                    for case let group as [String: Any] in groups {
                        guard let forumValues = group["forums"] as? [Any] else { continue }
                        for case let dictionary as [String: Any] in forumValues {
                            if let forum = forum(
                                from: dictionary,
                                category: categoryName,
                                iconPrefix: iconPrefix
                            ) {
                                result.append(forum)
                            }
                        }
                    }
                }
                guard !result.isEmpty else {
                    throw NGAServiceError.unexpectedPage("官方版面目录返回为空")
                }
                return unique(result)
            }

            let result: [Forum] = dictionaries(in: root).compactMap { dictionary in
                self.forum(from: dictionary)
            }
            if !result.isEmpty { return unique(result) }
        }
        let text = try response.decodedString()
        let document = try SwiftSoup.parse(text, response.url.absoluteString)
        var result: [Forum] = []
        for link in try document.select("a[href*='thread.php?fid='], a[href*='thread.php?stid=']") {
            guard let target = absoluteURL(try link.attr("href"), relativeTo: response.url) else { continue }
            let forumID: ForumID
            if let stid = queryInt64("stid", in: target) {
                forumID = ForumID(stid: stid)
            } else if let fid = queryInt64("fid", in: target) {
                forumID = ForumID(rawValue: fid)
            } else {
                continue
            }
            let name = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            result.append(Forum(id: forumID, name: name))
        }
        guard !result.isEmpty else { throw NGAServiceError.unexpectedPage("未找到版面目录") }
        return unique(result)
    }

    func favoriteForums(from response: NGAHTTPResponse) throws -> [Forum] {
        if let root = jsonRoot(response.data) {
            if let dictionary = root as? [String: Any],
               let code = int(dictionary["code"]),
               code != 0 {
                let message = string(dictionary["msg"]) ?? flattenedText(dictionary)
                if code == 5 || message.contains("登录") {
                    throw NGAServiceError.requiresLogin
                }
                throw NGAServiceError.restricted(concise(message))
            }

            let result = dictionaries(in: root).compactMap { dictionary in
                self.forum(from: dictionary)
            }
            if !result.isEmpty { return unique(result) }

            let text = flattenedText(root)
            if text.contains("没有收藏") || text.contains("暂无收藏") {
                return []
            }
            if let dictionary = root as? [String: Any],
               dictionary["result"] != nil ||
                dictionary["data"] != nil ||
                dictionary["item"] != nil ||
                dictionary["0"] != nil {
                return []
            }
        }

        let text = try response.decodedString()
        if text.contains("没有收藏") || text.contains("暂无收藏") {
            return []
        }
        let document = try SwiftSoup.parse(text, response.url.absoluteString)
        var result: [Forum] = []
        for link in try document.select("a[href*='thread.php?fid='], a[href*='thread.php?stid=']") {
            guard let target = absoluteURL(try link.attr("href"), relativeTo: response.url) else { continue }
            let id: ForumID
            if let stid = queryInt64("stid", in: target) {
                id = ForumID(stid: stid)
            } else if let fid = queryInt64("fid", in: target) {
                id = ForumID(rawValue: fid)
            } else {
                continue
            }
            let name = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { result.append(Forum(id: id, name: name)) }
        }
        guard !result.isEmpty else {
            throw NGAServiceError.unexpectedPage("未找到账号收藏版面")
        }
        return unique(result)
    }

    func forumPage(from response: NGAHTTPResponse, forumID: ForumID, page: Int) throws -> ForumPage {
        if let root = jsonRoot(response.data) {
            let forumMetadata = dictionaries(in: root)
                .compactMap { $0["__F"] as? [String: Any] }
                .first
            let subforums = forumMetadata.map(subforums(from:)) ?? []
            let subforumNames = Dictionary(
                uniqueKeysWithValues: subforums.map { ($0.id, $0.name) }
            )
            let topics = dictionaries(in: root).compactMap {
                parseTopic(from: $0, fallbackForumID: forumID)
            }.map { topic in
                var topic = topic
                if topic.sourceForumID == forumID {
                    topic.sourceForumID = nil
                    topic.sourceParentForumID = nil
                    topic.sourceForumName = nil
                } else if let sourceForumID = topic.sourceForumID,
                          topic.sourceForumName?.isEmpty != false {
                    topic.sourceForumName = subforumNames[sourceForumID]
                }
                return topic
            }
            if !topics.isEmpty {
                let totalPages = forumPageCount(
                    in: root,
                    currentPage: page,
                    fallbackTopicCount: topics.count
                )
                let parsedForum: Forum?
                if forumID.isSubforum {
                    parsedForum = subforums.first { $0.id == forumID }
                        ?? forumMetadata
                            .flatMap { string($0["set_topic_subject"]) }
                            .flatMap { name in
                                name.isEmpty ? nil : Forum(id: forumID, name: name)
                            }
                } else {
                    parsedForum = forumMetadata.flatMap {
                        self.forum(from: $0)
                    }.flatMap { $0.id == forumID ? $0 : nil }
                }
                return ForumPage(
                    forum: parsedForum,
                    topics: unique(topics),
                    page: page,
                    hasMore: page < totalPages,
                    totalPages: totalPages,
                    subforums: subforums.filter { $0.id != forumID }
                )
            }
        }

        let text = try response.decodedString()
        let document = try SwiftSoup.parse(text, response.url.absoluteString)
        var topics: [Topic] = []
        for link in try document.select("a[href*='read.php?tid=']") {
            guard let target = absoluteURL(try link.attr("href"), relativeTo: response.url),
                  let tid = queryInt64("tid", in: target) else { continue }
            let subject = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty else { continue }
            let containerText = try link.parent()?.parent()?.text() ?? subject
            topics.append(Topic(
                id: TopicID(rawValue: tid),
                forumID: forumID,
                subject: subject,
                author: extractAuthor(from: containerText),
                replyCount: extractReplyCount(from: containerText),
                publishedAt: nil,
                lastReplyAt: nil,
                isPinned: containerText.contains("置顶"),
                isLocked: containerText.contains("锁定")
            ))
        }
        guard !topics.isEmpty else { throw NGAServiceError.unexpectedPage("未找到话题列表") }
        let paginationPages = try document.select("a[href*='page=']").compactMap { link -> Int? in
            guard let target = absoluteURL(try link.attr("href"), relativeTo: response.url) else {
                return nil
            }
            return queryInt64("page", in: target).map(Int.init)
        }
        let hasNextPage = topics.count >= 20
        let totalPages = max(
            page,
            paginationPages.max() ?? 1,
            hasNextPage ? page + 1 : page
        )
        return ForumPage(
            forum: nil,
            topics: unique(topics),
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    func favoriteTopicPage(from response: NGAHTTPResponse, page: Int) throws -> ForumPage {
        if let root = jsonRoot(response.data) {
            try throwJSONErrorIfPresent(in: root)
            let topics = dictionaries(in: root).compactMap {
                parseTopic(from: $0, fallbackForumID: ForumID(rawValue: 0))
            }.map { topic in
                var topic = topic
                topic.isFavorite = true
                return topic
            }
            let totalPages = forumPageCount(
                in: root,
                currentPage: page,
                fallbackTopicCount: topics.count
            )
            return ForumPage(
                forum: nil,
                topics: unique(topics),
                page: page,
                hasMore: page < totalPages,
                totalPages: totalPages
            )
        }

        let text = try response.decodedString()
        if text.contains("没有收藏") || text.contains("暂无收藏") {
            return ForumPage(
                forum: nil,
                topics: [],
                page: page,
                hasMore: false,
                totalPages: max(1, page)
            )
        }
        var result = try forumPage(
            from: response,
            forumID: ForumID(rawValue: 0),
            page: page
        )
        result.topics = result.topics.map { topic in
            var topic = topic
            topic.isFavorite = true
            return topic
        }
        return result
    }

    func favoriteTopicFolders(from response: NGAHTTPResponse) throws -> [TopicFavoriteFolder] {
        let text = try response.decodedString()
        guard let root = jsonRoot(response.data) ?? jsonRoot(text) else {
            throw NGAServiceError.unexpectedPage("未找到收藏目录数据")
        }
        try throwJSONErrorIfPresent(in: root)
        let folders = dictionaries(in: jsonPayload(in: root)).compactMap { dictionary -> TopicFavoriteFolder? in
            guard let id = nonEmptyString(dictionary["id"]),
                  let name = nonEmptyString(dictionary["name"]) else {
                return nil
            }
            return TopicFavoriteFolder(
                id: id,
                name: plainText(name),
                topicCount: max(0, int(dictionary["length"]) ?? int(dictionary["topic_count"]) ?? 0),
                isPublic: marker(dictionary["public"])
                    || marker(dictionary["is_public"])
                    || ((int(dictionary["opt"]) ?? 0) & 1) != 0,
                isDefault: marker(dictionary["default"])
                    || marker(dictionary["is_default"])
                    || ((int(dictionary["opt"]) ?? 0) & 2) != 0
            )
        }
        let uniqueFolders = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values
        return uniqueFolders.sorted { left, right in
            if left.isDefault != right.isDefault { return left.isDefault }
            switch (Int64(left.id), Int64(right.id)) {
            case let (leftID?, rightID?) where leftID != rightID:
                return leftID < rightID
            default:
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
    }

    func createdTopicFavoriteFolderID(from response: NGAHTTPResponse) throws -> String? {
        let text = try response.decodedString()
        guard let root = jsonRoot(response.data) ?? jsonRoot(text) else {
            throw NGAServiceError.ambiguousWrite
        }
        try throwJSONErrorIfPresent(in: root)
        let payload = jsonPayload(in: root)
        if let dictionary = payload as? [String: Any] {
            for key in ["1", "0", "folder", "folder_id", "id"] {
                if let value = nonEmptyString(dictionary[key]), value != "0" {
                    return value
                }
            }
        }
        return nil
    }

    private func forumPageCount(
        in root: Any,
        currentPage: Int,
        fallbackTopicCount: Int
    ) -> Int {
        if let metadata = dictionaries(in: root).first(where: {
            $0["__ROWS"] != nil && $0["__T__ROWS_PAGE"] != nil
        }),
           let totalRows = int(metadata["__ROWS"]),
           let rowsPerPage = int(metadata["__T__ROWS_PAGE"]),
           totalRows > 0,
           rowsPerPage > 0 {
            return max(currentPage, (totalRows + rowsPerPage - 1) / rowsPerPage)
        }
        return max(currentPage, fallbackTopicCount >= 20 ? currentPage + 1 : currentPage)
    }

    func threadPage(from response: NGAHTTPResponse, topicID: TopicID, page: Int) throws -> ThreadPage {
        if let root = jsonRoot(response.data) {
            try throwJSONErrorIfPresent(in: root)
            let payload = threadPayload(in: root)
            let topicMetadata: [String: Any]?
            if let payload {
                topicMetadata = topicDictionary(in: payload, topicID: topicID)
            } else {
                topicMetadata = nil
            }
            var topic = topicMetadata.flatMap {
                parseTopic(from: $0, fallbackForumID: ForumID(rawValue: 0))
            }
                ?? dictionaries(in: root)
                    .compactMap { parseTopic(from: $0, fallbackForumID: ForumID(rawValue: 0)) }
                    .first { $0.id == topicID }
                ?? Topic(id: topicID, forumID: ForumID(rawValue: 0), subject: "帖子 \(topicID.rawValue)", author: "", replyCount: 0, isPinned: false, isLocked: false)
            let customLevelSource = (payload?["__F"] as? [String: Any])
                .flatMap { string($0["custom_level"]) }
            var users = payload
                .flatMap { $0["__U"] }
                .map { userMap(in: $0, customLevelSource: customLevelSource) }
                ?? postUsers(in: root)
            if let topicMetadata,
               let authorUID = postAuthorID(in: topicMetadata),
               let author = normalizedUsername(string(topicMetadata["author"])) {
                if var existing = users[authorUID] {
                    existing.name = author
                    users[authorUID] = existing
                } else {
                    users[authorUID] = PostUser(name: author, avatarURL: nil, authorInfo: nil)
                }
            }
            let postValues = postDictionaries(in: root, payload: payload)
            topic.rating = topicMetadata
                .flatMap(topicVoteValue)
                .flatMap { topicRating(from: $0, topicID: topicID) }
                ?? postValues.lazy.compactMap {
                    string($0["vote"]).flatMap {
                        topicRating(from: $0, topicID: topicID)
                    }
                }.first
            let posts = postValues.compactMap { dictionary in
                post(
                    from: dictionary,
                    topicID: topicID,
                    users: users,
                    topicAuthor: topic.author
                )
            }
                .sorted(by: postOrder)
            if !posts.isEmpty {
                let hotReplies = hotReplyDictionaries(in: payload).compactMap { dictionary in
                    post(
                        from: dictionary,
                        topicID: topicID,
                        users: users,
                        topicAuthor: topic.author
                    )
                }
                let totalPages = threadPageCount(
                    in: root,
                    topic: topic,
                    currentPage: page,
                    postCount: posts.count
                )
                return ThreadPage(
                    topic: topic,
                    posts: unique(posts),
                    hotReplies: unique(hotReplies),
                    page: page,
                    hasMore: page < totalPages,
                    totalPages: totalPages
                )
            }
        }

        let text = try response.decodedString()
        let document = try SwiftSoup.parse(text, response.url.absoluteString)
        let pageTitle = try document.title().replacingOccurrences(of: " - NGA玩家社区", with: "")
        let headingTitle = try document.select("#currentTopicName").first?.text()
        let title = headingTitle.flatMap { $0.isEmpty ? nil : $0 } ?? pageTitle
        let htmlUsers = htmlUserMap(in: text)
        let htmlPostMetadata = htmlPostMetadata(in: text)
        let htmlTopicPoll = htmlTopicPoll(in: text, topicID: topicID)
        let htmlRatings = htmlRatings(in: text, topicID: topicID)
        var posts: [Post] = []
        let rows = try document.select("tr.postrow, .postrow, .post-row")
        if !rows.isEmpty {
            for row in rows {
                guard let floor = try htmlFloor(in: row) else { continue }
                let metadata = htmlPostMetadata[floor]
                let content = try htmlPostContent(in: row, floor: floor)
                guard let content else { continue }
                let contentHTML = try content.html()
                let authorUID = metadata?.authorUID
                let user = authorUID.flatMap { htmlUsers[$0] }
                let inlineAuthor = try row.select(
                    "#postauthor\(floor), [id^='postauthor'], .author, [class*='author']"
                ).first?.text()
                posts.append(Post(
                    id: PostID(rawValue: metadata?.pid ?? stableID(
                        for: "\(topicID.rawValue):\(floor):\(contentHTML)"
                    )),
                    topicID: topicID,
                    floor: floor,
                    author: user?.name ?? normalizedUsername(inlineAuthor) ?? "",
                    authorUID: authorUID,
                    avatarURL: user?.avatarURL,
                    authorInfo: user?.authorInfo,
                    postedAt: metadata?.postedAt,
                    device: metadata?.device ?? .desktop,
                    html: contentHTML,
                    upvoteCount: metadata?.upvoteCount ?? 0,
                    downvoteCount: metadata?.downvoteCount ?? 0,
                    poll: floor == 0 ? htmlTopicPoll : nil,
                    ratingScores: htmlRatings.postScores[floor] ?? [:]
                ))
            }
        } else {
            var fallbackID: Int64 = Int64(page * 10_000)
            let candidates = try document.select(
                "[id^='postcontent'], [id^='post_content'], .postcontent, .postContent"
            ).filter { !isHTMLPostContentAndSubjectWrapper($0) }
            for element in candidates {
                let elementID = element.id()
                let floor = digits(in: elementID).flatMap(Int.init)
                    ?? posts.count + max(0, page - 1) * 20
                let pid = digits(in: elementID).flatMap(Int64.init) ?? fallbackID
                fallbackID += 1
                let author = try element.parent()?.select(
                    ".author, [class*='author'], [id^='postauthor']"
                ).first()?.text() ?? ""
                posts.append(Post(
                    id: PostID(rawValue: pid),
                    topicID: topicID,
                    floor: floor,
                    author: normalizedUsername(author) ?? "",
                    postedAt: nil,
                    device: .desktop,
                    html: try element.html(),
                    poll: floor == 0 ? htmlTopicPoll : nil,
                    ratingScores: htmlRatings.postScores[floor] ?? [:]
                ))
            }
        }
        guard !posts.isEmpty else { throw NGAServiceError.unexpectedPage("未找到帖子楼层") }
        posts.sort(by: postOrder)
        let topic = Topic(
            id: topicID,
            forumID: ForumID(rawValue: 0),
            subject: title,
            author: posts.first(where: { $0.floor == 0 })?.author ?? "",
            authorUID: posts.first(where: { $0.floor == 0 })?.authorUID,
            replyCount: max(0, posts.map(\.floor).max() ?? 0),
            isPinned: false,
            isLocked: false,
            rating: htmlRatings.topicRating
        )
        let linkedPages = try document.select("a[href*='page=']").compactMap { element -> Int? in
            guard let href = try? element.attr("href"),
                  let components = URLComponents(string: href) else {
                return nil
            }
            return components.queryItems?
                .first(where: { $0.name == "page" })?
                .value
                .flatMap(Int.init)
        }
        let filtersByAuthor = URLComponents(url: response.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == "authorid" }) == true
        let totalPages = filtersByAuthor
            ? max(page, linkedPages.max() ?? page)
            : max(
                threadPageCount(topic: topic, currentPage: page, postCount: posts.count),
                linkedPages.max() ?? 1
            )
        return ThreadPage(
            topic: topic,
            posts: unique(posts),
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    private func threadPageCount(topic: Topic, currentPage: Int, postCount: Int) -> Int {
        // NGA 每页最多显示 20 个楼层；replyCount 不包含话题首帖。
        let countFromReplies = max(1, (topic.replyCount + 20) / 20)
        if topic.replyCount > 0 || postCount < 20 {
            return max(currentPage, countFromReplies)
        }
        // 结构化响应缺少话题元数据时，只能用满页结果保守探测下一页。
        return currentPage + 1
    }

    private func threadPageCount(
        in root: Any,
        topic: Topic,
        currentPage: Int,
        postCount: Int
    ) -> Int {
        if let metadata = dictionaries(in: root).first(where: {
            $0["__ROWS"] != nil && $0["__R__ROWS_PAGE"] != nil
        }),
           let totalRows = int(metadata["__ROWS"]),
           let rowsPerPage = int(metadata["__R__ROWS_PAGE"]),
           totalRows >= 0,
           rowsPerPage > 0 {
            let totalPages = max(1, (totalRows + rowsPerPage - 1) / rowsPerPage)
            return max(currentPage, totalPages)
        }
        return threadPageCount(topic: topic, currentPage: currentPage, postCount: postCount)
    }

    func messages(from response: NGAHTTPResponse, folder: MessageFolder, page: Int) throws -> MessagePage {
        if let root = jsonRoot(response.data) {
            try throwJSONErrorIfPresent(in: root)
            let rawPayload = jsonPayload(in: root)
            let payload = folder == .notifications
                ? notificationPayload(in: rawPayload)
                : rawPayload
            var values: [ForumMessage]
            if folder == .notifications {
                values = dictionaries(in: payload)
                    .compactMap(notificationMessage(from:))
                    .sorted {
                        ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast)
                    }
                if let unreadCount = notificationUnreadCount(in: payload) {
                    let unreadStart = max(0, values.count - unreadCount)
                    for index in values.indices {
                        values[index].isUnread = index >= unreadStart
                    }
                }
                values.reverse()
            } else {
                values = dictionaries(in: payload).compactMap { message(from: $0, folder: folder) }
            }
            if !values.isEmpty {
                return MessagePage(
                    folder: folder,
                    messages: unique(values),
                    page: page,
                    hasMore: folder == .privateMessages && values.count >= 20
                )
            }
            if isKnownMessageEnvelope(payload) {
                return MessagePage(folder: folder, messages: [], page: page, hasMore: false)
            }
        }

        let text = try response.decodedString()
        let document = try SwiftSoup.parse(text, response.url.absoluteString)
        var result: [ForumMessage] = []
        for link in try document.select("a[href*='mid='], a[href*='notification']") {
            guard let target = absoluteURL(try link.attr("href"), relativeTo: response.url) else { continue }
            let mid = queryInt64("mid", in: target) ?? stableID(for: target.absoluteString)
            let subject = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty else { continue }
            let rowText = try link.parent()?.parent()?.text() ?? subject
            result.append(ForumMessage(
                id: MessageID(rawValue: mid),
                kind: kind(from: rowText, folder: folder),
                sender: "",
                subject: subject,
                preview: rowText,
                sentAt: nil,
                isUnread: rowText.contains("未读") || (try? link.className().contains("unread")) == true,
                topicID: queryInt64("tid", in: target).map(TopicID.init(rawValue:)),
                replyURL: target
            ))
        }
        if result.isEmpty, text.contains("暂无") || text.contains("没有消息") {
            return MessagePage(folder: folder, messages: [], page: page, hasMore: false)
        }
        guard !result.isEmpty else { throw NGAServiceError.unexpectedPage("未找到消息列表") }
        return MessagePage(folder: folder, messages: unique(result), page: page, hasMore: result.count >= 20)
    }

    func message(from response: NGAHTTPResponse, id: MessageID) throws -> ForumMessage {
        if let root = jsonRoot(response.data) {
            try throwJSONErrorIfPresent(in: root)
            let payload = jsonPayload(in: root)
            if let container = dictionaries(in: payload).first(where: { $0["allmsgs"] != nil }),
               let allMessages = container["allmsgs"] {
                let users = userMap(in: container["userInfo"] ?? [:])
                let items = dictionaries(in: allMessages).filter {
                    int64($0["id"]) != nil && string($0["content"]) != nil
                }
                if !items.isEmpty {
                    let subject = items.compactMap { string($0["subject"]) }
                        .first(where: { !$0.isEmpty }) ?? "私信"
                    let posts = items.compactMap { dictionary -> ForumMessagePost? in
                        guard let rawID = int64(dictionary["id"]),
                              let content = string(dictionary["content"]) else {
                            return nil
                        }
                        let uid = int64(dictionary["from"]) ?? int64(dictionary["from_uid"])
                        let name = normalizedUsername(string(dictionary["from_username"]))
                            ?? uid.flatMap { users[$0]?.name }
                            ?? "未知用户"
                        return ForumMessagePost(
                            id: MessageID(rawValue: rawID),
                            author: name,
                            authorUID: uid,
                            avatarURL: uid.flatMap { users[$0]?.avatarURL },
                            sentAt: date(dictionary["time"]),
                            html: content
                        )
                    }
                    .sorted { lhs, rhs in
                        if lhs.sentAt != rhs.sentAt {
                            return (lhs.sentAt ?? .distantPast) < (rhs.sentAt ?? .distantPast)
                        }
                        return lhs.id.rawValue < rhs.id.rawValue
                    }
                    let sender = posts.first?.author ?? ""
                    let articles = posts.map { post in
                        return """
                        <article>
                          <header><strong>\(htmlEscaped(post.author))</strong></header>
                          <div>\(post.html)</div>
                        </article>
                        """
                    }
                    return ForumMessage(
                        id: id,
                        kind: .privateMessage,
                        sender: sender,
                        subject: subject,
                        preview: posts.last?.html ?? "",
                        html: articles.joined(separator: "<hr>"),
                        sentAt: posts.last?.sentAt,
                        isUnread: false,
                        replyURL: response.url,
                        posts: posts
                    )
                }
            }
        }

        let text = try response.decodedString()
        let document = try SwiftSoup.parse(text, response.url.absoluteString)
        let subject = (try? document.select("h1, .subject, [class*='subject']").first()?.text()) ?? "私信"
        let sender = (try? document.select(".author, [class*='author']").first()?.text()) ?? ""
        let contentElement = try document.select(".msgcontent, .message-content, [id*='message'], #m_posts_c").first()
        let html = try contentElement?.html() ?? document.body()?.html() ?? ""
        let replyLink = try document.select("a[href*='reply'], a[href*='action=send']").first().flatMap {
            absoluteURL(try $0.attr("href"), relativeTo: response.url)
        }
        return ForumMessage(
            id: id,
            kind: .privateMessage,
            sender: sender,
            subject: subject,
            preview: try contentElement?.text() ?? "",
            html: html,
            sentAt: nil,
            isUnread: false,
            replyURL: replyLink,
            posts: [
                ForumMessagePost(
                    id: id,
                    author: sender,
                    html: html
                )
            ]
        )
    }

    func checkIn(from response: NGAHTTPResponse) throws -> CheckInResult {
        let text = try response.decodedString()
        if let root = jsonRoot(response.data) ?? jsonRoot(text) {
            let message = flattenedStringText(root)
            if message.contains("已签到") || message.contains("已经签到") || message.contains("今天已经签到") {
                return .alreadyCheckedIn(message: checkInAlreadyCompletedMessage(from: message))
            }
            if message.localizedCaseInsensitiveContains("client error") {
                throw NGAServiceError.restricted("签到请求被 NGA 拒绝，请稍后重试")
            }
            try throwJSONErrorIfPresent(in: root)
            if message.contains("成功") || (message.contains("签到") && !message.contains("失败")) {
                return .success(message: CheckInPolicy.userFacingSuccessMessage(from: message))
            }
            // 当前签到接口成功时可能只返回 {"data": null, "time": ...}，
            // 没有文案；只要结构化响应中存在 data 且没有 error 即可确认成功。
            if let dictionary = root as? [String: Any], dictionary.keys.contains("data") {
                return .success(message: "签到成功")
            }
        }
        let message = text
        if message.contains("已签到") || message.contains("已经签到") {
            return .alreadyCheckedIn(message: checkInAlreadyCompletedMessage(from: message))
        }
        if message.contains("成功") || (message.contains("签到") && !message.contains("失败")) {
            return .success(message: CheckInPolicy.userFacingSuccessMessage(from: message))
        }
        throw NGAServiceError.unexpectedPage("无法确认签到结果")
    }

    private func checkInAlreadyCompletedMessage(from source: String) -> String {
        let message = concise(source)
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"服务器时间\s*([0-9]{4}-[0-9]{2}-[0-9]{2}\s+[0-9]{2}:[0-9]{2}:[0-9]{2})"#,
            options: .caseInsensitive
        ) else {
            return "今日已签到"
        }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = expression.firstMatch(in: message, range: range),
              let valueRange = Range(match.range(at: 1), in: message) else {
            return "今日已签到"
        }
        return "今日已签到（服务器时间 \(message[valueRange])）"
    }

    func submissionSucceeded(from response: NGAHTTPResponse) throws -> PostID? {
        let text = try response.decodedString()
        if text.contains("ERROR:") || text.contains("操作失败") || text.contains("发送失败") {
            throw NGAServiceError.restricted(concise(text))
        }
        if let root = jsonRoot(response.data) {
            for dictionary in dictionaries(in: root) {
                if let pid = int64(dictionary["pid"]) { return PostID(rawValue: pid) }
            }
        }
        let document = try SwiftSoup.parse(text, response.url.absoluteString)
        let messageItems = structuredMessageItems(in: text)
        if !messageItems.isEmpty {
            let message = messageItems.dropFirst().first(where: { !$0.isEmpty })
                ?? messageItems.first(where: { !$0.isEmpty })
                ?? ""
            if message.contains("完毕") || message.contains("成功") {
                return nil
            }
            if message.contains("登录") {
                throw NGAServiceError.requiresLogin
            }
            throw NGAServiceError.restricted(concise(message))
        }
        if let pidText = try document.select("root > pid").first()?.text(),
           let pid = Int64(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return PostID(rawValue: pid)
        }
        if text.contains("成功") || text.contains("正在跳转") || response.statusCode == 302 {
            return nil
        }
        throw NGAServiceError.ambiguousWrite
    }

    func actionSucceeded(from response: NGAHTTPResponse) throws {
        let text = try response.decodedString()
        if let root = jsonRoot(response.data) {
            try throwJSONErrorIfPresent(in: root)
            if let dictionary = root as? [String: Any],
               let code = int(dictionary["code"]) {
                guard code == 0 else {
                    let message = string(dictionary["msg"]) ?? flattenedText(root)
                    if code == 5 || message.contains("登录") {
                        throw NGAServiceError.requiresLogin
                    }
                    throw NGAServiceError.restricted(concise(message))
                }
                return
            }
            let flattened = flattenedText(root)
            if flattened.contains("失败") || flattened.contains("错误") {
                throw NGAServiceError.restricted(concise(flattened))
            }
            return
        }
        if text.contains("成功") || text.contains("完成") || response.statusCode == 302 {
            return
        }
        if text.contains("失败") || text.contains("ERROR") {
            throw NGAServiceError.restricted(concise(text))
        }
        throw NGAServiceError.ambiguousWrite
    }

    func voteState(from response: NGAHTTPResponse) throws -> PostVoteState {
        let text = try response.decodedString()
        let document = try SwiftSoup.parse(text, response.url.absoluteString)
        let values = try document.select("data > item").compactMap { element in
            Int(try element.text().trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if values.count >= 3 {
            return PostVoteState(
                upvoteCount: max(0, values[0]),
                downvoteCount: max(0, values[1]),
                userVote: voteDirection(values[2])
            )
        }

        if let root = jsonRoot(response.data) {
            try throwJSONErrorIfPresent(in: root)
            for dictionary in dictionaries(in: jsonPayload(in: root)) {
                let up = int(dictionary["up"]) ?? int(dictionary["upvote"]) ?? int(dictionary["vote_up"])
                let down = int(dictionary["down"]) ?? int(dictionary["downvote"]) ?? int(dictionary["vote_down"])
                if let up, let down {
                    let selected = int(dictionary["user_vote"]) ?? int(dictionary["vote"])
                    return PostVoteState(
                        upvoteCount: max(0, up),
                        downvoteCount: max(0, down),
                        userVote: selected.flatMap(voteDirection)
                    )
                }
            }
        }

        if text.contains("ERROR:") || text.contains("失败") {
            throw NGAServiceError.restricted(concise(text))
        }
        throw NGAServiceError.ambiguousWrite
    }

    func form(from response: NGAHTTPResponse, requiredField: String) throws -> ParsedHTMLForm {
        let text = try response.decodedString()
        let document = try SwiftSoup.parse(text, response.url.absoluteString)
        for form in try document.select("form") {
            let namedFields = try form.select("input[name], textarea[name], select[name]")
            let names = try namedFields.map { try $0.attr("name") }
            guard names.contains(requiredField) else { continue }
            var values: [String: String] = [:]
            for field in namedFields {
                let name = try field.attr("name")
                guard !name.isEmpty else { continue }
                values[name] = try field.attr("value")
            }
            let rawAction = try form.attr("action")
            let action = absoluteURL(rawAction.isEmpty ? response.url.absoluteString : rawAction, relativeTo: response.url) ?? response.url
            return ParsedHTMLForm(action: action, fields: values)
        }

        // post.php 的当前轻量接口返回 XML，而不是带 <form> 的网页。预检响应中的
        // auth 是官方提交校验字段；正文在提交前由调用方写入 post_content。
        if try document.select("root").first() != nil {
            let messageItems = structuredMessageItems(in: text)
            if !messageItems.isEmpty {
                let message = messageItems.dropFirst().first(where: { !$0.isEmpty })
                    ?? messageItems.first(where: { !$0.isEmpty })
                    ?? ""
                if message.contains("登录") {
                    throw NGAServiceError.requiresLogin
                }
                throw NGAServiceError.restricted(concise(message))
            }

            let replyPayloadTags = ["auth", "content", "subject", "attach_url"]
            let hasReplyPayload = try replyPayloadTags.contains { tag in
                try document.select("root > \(tag)").first() != nil
            }
            if hasReplyPayload {
                var values: [String: String] = [:]
                if let auth = try document.select("root > auth").first()?.text(),
                   !auth.isEmpty {
                    values["auth"] = auth
                }
                return ParsedHTMLForm(action: response.url, fields: values)
            }
        }

        // 部分网页版本把编辑器控件放在脚本生成的表单之外。只要当前页面确实
        // 暴露了所需字段，就仍使用当前 URL 作为提交地址。
        let looseFields = try document.select("input[name], textarea[name], select[name]")
        let looseNames = try looseFields.map { try $0.attr("name") }
        if looseNames.contains(requiredField) {
            var values: [String: String] = [:]
            for field in looseFields {
                let name = try field.attr("name")
                guard !name.isEmpty else { continue }
                values[name] = try field.tagName() == "textarea" ? field.text() : field.attr("value")
            }
            return ParsedHTMLForm(action: response.url, fields: values)
        }
        throw NGAServiceError.unsupported("NGA 当前页面没有可用的提交表单")
    }

    private func structuredMessageItems(in source: String) -> [String] {
        // SwiftSoup 的 HTML 解析器会丢弃以 "_" 开头的 NGA XML 标签，
        // 因此只在已限定的 <__MESSAGE> 片段内提取 <item>，避免把正文误判为状态。
        guard let envelopeExpression = CachedRegularExpressions.shared.expression(
            pattern: #"<__MESSAGE\b[^>]*>([\s\S]*?)</__MESSAGE>"#,
            options: .caseInsensitive
        ) else { return [] }
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let envelopeMatch = envelopeExpression.firstMatch(in: source, range: sourceRange),
              let envelopeRange = Range(envelopeMatch.range(at: 1), in: source) else {
            return []
        }
        let envelope = String(source[envelopeRange])
        guard let itemExpression = CachedRegularExpressions.shared.expression(
            pattern: #"<item\b[^>]*>([\s\S]*?)</item>"#,
            options: .caseInsensitive
        ) else { return [] }
        let itemRange = NSRange(envelope.startIndex..<envelope.endIndex, in: envelope)
        return itemExpression.matches(in: envelope, range: itemRange).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: envelope) else { return nil }
            return plainText(String(envelope[capture]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func throwStructuredErrorIfPresent(in source: String) throws {
        let items = structuredMessageItems(in: source)
        guard !items.isEmpty else { return }
        let message = items.dropFirst().first(where: { !$0.isEmpty })
            ?? items.first(where: { !$0.isEmpty })
            ?? ""
        guard !message.isEmpty else { return }
        if explicitlyRequiresLogin(message) {
            throw NGAServiceError.requiresLogin
        }
        throw NGAServiceError.restricted(concise(message))
    }

    private func structuredItemDictionaries(
        in source: String,
        sectionName: String? = nil
    ) throws -> [[String: Any]] {
        let fragment: String
        if let sectionName {
            guard let value = structuredSection(named: sectionName, in: source) else {
                return []
            }
            fragment = value
        } else {
            fragment = structuredSection(named: "root", in: source) ?? source
        }
        let document = try SwiftSoup.parse(
            "<root>\(fragment)</root>",
            NGAEndpoint.baseURL.absoluteString,
            Parser.xmlParser()
        )
        return try document.getElementsByTag("item").compactMap { item in
            var dictionary: [String: Any] = [:]
            for child in item.children() {
                dictionary[child.tagName()] = try child.text()
            }
            return dictionary.isEmpty ? nil : dictionary
        }
    }

    private func structuredSection(named name: String, in source: String) -> String? {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"<\#(name)\b[^>]*>([\s\S]*?)</\#(name)>"#,
            options: .caseInsensitive
        ) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = expression.firstMatch(in: source, range: range),
              let capture = Range(match.range(at: 1), in: source) else {
            return nil
        }
        return String(source[capture])
    }

    private func structuredInteger(named name: String, in source: String) -> Int? {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"<\#(name)\b[^>]*>\s*(-?\d+)\s*</\#(name)>"#,
            options: .caseInsensitive
        ) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = expression.firstMatch(in: source, range: range),
              let capture = Range(match.range(at: 1), in: source) else {
            return nil
        }
        return Int(source[capture])
    }

    /// 可复用的楼层清洗器。整页楼层的白名单规则完全相同，构造一次即可反复使用，
    /// 省掉逐楼重建 `Whitelist` 的十余次 addTags/addAttributes。
    ///
    /// 持有 `Whitelist`（SwiftSoup 的 class，非 Sendable），因此只应在单次
    /// 解析调用内部使用，不要跨隔离域传递。清洗过程只读取白名单，不修改它。
    struct PostHTMLSanitizer {
        fileprivate let parser: NGAParser
        fileprivate let whitelist: Whitelist?

        /// 清洗出楼层正文，同时给出可原生渲染的结构（无法原生还原时为 nil）。
        func post(
            _ source: String,
            topicRating: TopicRating? = nil
        ) -> SanitizedPost {
            parser.sanitizedPost(
                source,
                topicRating: topicRating,
                whitelist: whitelist
            )
        }

        func callAsFunction(
            _ source: String,
            topicRating: TopicRating? = nil
        ) -> String {
            post(source, topicRating: topicRating).html
        }
    }

    func makePostHTMLSanitizer() -> PostHTMLSanitizer {
        PostHTMLSanitizer(parser: self, whitelist: try? Self.makePostWhitelist())
    }

    func sanitizedPostHTML(
        _ source: String,
        topicRating: TopicRating? = nil
    ) -> String {
        makePostHTMLSanitizer()(source, topicRating: topicRating)
    }

    func sanitizedPost(
        _ source: String,
        topicRating: TopicRating? = nil
    ) -> SanitizedPost {
        makePostHTMLSanitizer().post(source, topicRating: topicRating)
    }

    private static func makePostWhitelist() throws -> Whitelist {
        try Whitelist.relaxed()
            .addTags("details", "summary", "section", "hr", "button")
            .addAttributes("a", "class")
            .addAttributes(
                "button",
                "class",
                "type",
                "data-snga-random-block-index",
                "aria-label",
                "aria-pressed"
            )
            .addAttributes(
                "img",
                "class",
                "width",
                "height",
                "loading",
                "decoding",
                "referrerpolicy"
            )
            .addAttributes("span", "class")
            .addAttributes("div", "class", "role", "aria-label", "aria-hidden")
            .addAttributes("h3", "class")
            .addAttributes("section", "class")
            .addAttributes("details", "open")
            .addAttributes("td", "width", "colspan", "rowspan")
            .addAttributes("th", "width", "colspan", "rowspan")
    }

    private func sanitizedPost(
        _ source: String,
        topicRating: TopicRating?,
        whitelist: Whitelist?
    ) -> SanitizedPost {
        let rendered = renderBBCode(source, topicRating: topicRating)
        var clean: String
        var nativeContent: PostContent?
        do {
            guard let whitelist else { throw NGAServiceError.invalidResponse }
            let document = try SwiftSoup.parseBodyFragment(rendered.html, NGAEndpoint.baseURL.absoluteString)
            for element in try document.select("*") {
                for textNode in element.textNodes() {
                    let current = textNode.getWholeText()
                    let decoded = decodedHTMLEntities(current)
                    if decoded != current {
                        textNode.text(decoded)
                    }
                }
            }
            for image in try document.select("img") {
                let rawSource = try image.attr("src")
                if let resolved = remoteResourceURL(rawSource, kind: .attachment) {
                    try image.attr("src", resolved.absoluteString)
                    try image.attr("loading", "eager")
                    try image.attr("decoding", "async")
                    try image.attr("referrerpolicy", "no-referrer")
                    if resolved.path.localizedCaseInsensitiveContains("/ngabbs/post/smile/") {
                        try image.addClass("nga-smile")
                    }
                } else {
                    try image.remove()
                }
            }
            for link in try document.select("a[href]") {
                let rawTarget = try link.attr("href")
                if let target = absoluteURL(rawTarget, relativeTo: NGAEndpoint.baseURL),
                   ["http", "https", "mailto"].contains(target.scheme?.lowercased() ?? "") {
                    try link.attr("href", secureURL(target)?.absoluteString ?? target.absoluteString)
                } else {
                    try link.removeAttr("href")
                }
            }

            // 直接清洗已解析的 DOM，而不是先序列化再交给 `SwiftSoup.clean` ——
            // 后者会把同一份内容重新解析一遍，等于每个楼层解析两次。
            // （`SwiftSoup.clean` 额外做的 nbsp 归一化只对纯文本白名单生效，这里不适用。）
            let cleaner = Cleaner(headWhitelist: nil, bodyWhitelist: whitelist)
            guard let cleanBody = try cleaner.clean(document).body() else {
                throw NGAServiceError.invalidResponse
            }
            nativeContent = PostContentBuilder.content(from: cleanBody)
            clean = compactedPostSpacing(try cleanBody.html())
        } catch {
            clean = "<p>内容无法显示</p>"
            nativeContent = nil
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; font-src 'none'; media-src https:">
        <style>
        :root{color-scheme:light dark;--snga-accent:#b06d00;--snga-highlight:#d59b3a;--snga-smile-backdrop-system:transparent;--snga-smile-backdrop:var(--snga-smile-backdrop-system)}@media(prefers-color-scheme:dark){:root{--snga-smile-backdrop-system:rgba(255,255,255,.88)}}html,body{width:100%;max-width:100%;overflow-x:hidden;overflow-y:hidden}body{font:14px -apple-system,BlinkMacSystemFont,sans-serif;margin:0;color:CanvasText;background:transparent;overflow-wrap:anywhere;line-height:1.55}
        #snga-post-content{display:flow-root;width:100%;max-width:100%;min-height:1px}#snga-post-content>:first-child{margin-top:0}#snga-post-content>:last-child:not(blockquote){margin-bottom:0}p{margin:6px 0}
        img{max-width:100%;height:auto;vertical-align:middle}.nga-smile{max-width:64px;max-height:64px;background:var(--snga-smile-backdrop);border-radius:6px}table{width:100%;max-width:100%;border-collapse:collapse;table-layout:auto}td,th{min-width:0;border:1px solid color-mix(in srgb,CanvasText 20%,transparent);padding:6px;vertical-align:top;overflow-wrap:anywhere}.ubb-split-row{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.ubb-split-left{text-align:left}.ubb-split-right{text-align:right}
        .snga-image-placeholder{display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box;min-width:132px;min-height:58px;max-width:100%;margin:3px 0;padding:10px 14px;border:1px dashed color-mix(in srgb,var(--snga-accent) 55%,CanvasText 20%);border-radius:7px;color:var(--snga-accent);background:color-mix(in srgb,var(--snga-accent) 8%,transparent);cursor:pointer;user-select:none}.snga-image-placeholder:hover,.snga-image-placeholder:focus{background:color-mix(in srgb,var(--snga-accent) 15%,transparent);outline:1px solid color-mix(in srgb,var(--snga-accent) 45%,transparent);outline-offset:1px}.nga-rich-card-image .snga-image-placeholder{display:flex}
        ul,ol{margin:8px 0;padding-left:1.6em}li{margin:4px 0}hr{height:1px;margin:12px 0;border:0;background:color-mix(in srgb,CanvasText 22%,transparent)}
        blockquote{margin:8px 0 12px;padding:6px 10px;border-left:3px solid var(--snga-highlight);background:color-mix(in srgb,CanvasText 7%,transparent)}a{color:var(--snga-accent)}.nga-post-reference{display:inline-block;font-weight:600;text-decoration:none;border-bottom:1px dashed currentColor}pre,code{white-space:pre-wrap}
        details{margin:8px 0;padding:6px 10px;border:1px solid color-mix(in srgb,CanvasText 18%,transparent);border-radius:6px}summary{cursor:pointer;font-weight:600}.nga-section-title{margin:14px 0 8px;font-size:1.15em}
        .nga-random-block-panel{display:none}.nga-random-block-panel.snga-is-active{display:block}.nga-random-block-controls{display:flex;align-items:center;justify-content:center;min-height:28px;margin:1px 0 4px;overflow:hidden}.nga-random-block-button{position:relative;width:44px;height:28px;margin:0 2px;padding:0;border:0;border-radius:8px;color:inherit;background:transparent;cursor:pointer}.nga-random-block-button::before{position:absolute;top:10px;left:10px;width:24px;height:8px;border-radius:999px;background:color-mix(in srgb,CanvasText 22%,transparent);content:""}.nga-random-block-button.snga-is-active::before{background:var(--snga-highlight)}.nga-random-block-button:hover::before{background:color-mix(in srgb,var(--snga-highlight) 72%,CanvasText)}.nga-random-block-button:focus-visible{outline:2px solid var(--snga-highlight);outline-offset:-3px}
        .nga-rich-card{margin:8px 0 12px;padding:12px;border:1px solid color-mix(in srgb,CanvasText 14%,transparent);border-radius:10px;background:color-mix(in srgb,var(--snga-highlight) 8%,transparent)}
        .nga-rich-card-title{margin:0 0 8px;font-size:1.15em}.nga-rich-card-image{margin:6px 0}.nga-rich-card-image img{display:block;border-radius:7px}
        .nga-game-card{display:grid;grid-template-columns:minmax(88px,9rem) minmax(0,1fr);gap:12px;margin:8px 0 12px;padding:14px;box-sizing:border-box;border:1px solid color-mix(in srgb,CanvasText 14%,transparent);border-radius:10px;color:CanvasText;background:color-mix(in srgb,var(--snga-highlight) 9%,transparent)}.nga-game-card-no-score{grid-template-columns:minmax(0,1fr)}
        .nga-game-score{display:flex;min-height:88px;box-sizing:border-box;flex-direction:column;align-items:center;justify-content:center;padding:8px;border-radius:7px;color:#fff;background:#b22222;text-align:center}.nga-game-score-value{font-size:2.75em;font-weight:700;line-height:1;font-variant-numeric:tabular-nums}.nga-game-score-count{margin-top:7px;font-size:.9em;font-weight:600}
        .nga-game-heading{align-self:center;min-width:0}.nga-game-title{margin:0;font-size:1.8em;line-height:1.2;overflow-wrap:anywhere}.nga-game-subtitle{margin-top:5px;font-size:1.05em}.nga-game-release{display:flex;flex-wrap:wrap;gap:6px 12px;margin-top:9px}.nga-game-release-item{display:inline-flex;align-items:center;gap:6px;white-space:nowrap}.nga-game-platform{padding:1px 7px;border-radius:4px;color:#fff;background:#0c7da8;font-weight:600}
        .nga-game-cover{grid-column:1/-1;overflow:hidden;border-radius:7px;background:color-mix(in srgb,CanvasText 6%,transparent)}.nga-game-cover img{display:block;width:100%;height:auto}.nga-game-cover .snga-image-placeholder{display:flex;width:100%}
        .nga-game-details{grid-column:1/-1;display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:14px 20px}.nga-game-field{min-width:0}.nga-game-label{font-size:1.05em;font-weight:650}.nga-game-value{margin-top:3px;color:#b22222;font-size:1.05em;overflow-wrap:anywhere}.nga-game-website{grid-column:1/-1}.nga-game-website a{display:inline-flex;align-items:center;gap:5px;color:#b22222;font-size:1.05em;font-weight:600}.nga-game-extra{grid-column:1/-1}
        @media(max-width:520px){.nga-game-card{grid-template-columns:76px minmax(0,1fr);gap:10px;padding:10px}.nga-game-card-no-score{grid-template-columns:1fr}.nga-game-score{min-height:76px}.nga-game-score-value{font-size:2.2em}.nga-game-score-count{font-size:.72em}.nga-game-title{font-size:1.4em}.nga-game-details{grid-template-columns:repeat(2,minmax(0,1fr))}.nga-game-website{grid-column:1/-1}}@media(max-width:360px){.nga-game-card{grid-template-columns:1fr}.nga-game-score{width:112px;min-height:72px}.nga-game-cover,.nga-game-details{grid-column:1}.nga-game-details{grid-template-columns:1fr}}
        .ubb-color-red{color:red}.ubb-color-orange{color:orange}.ubb-color-orangered{color:orangered}.ubb-color-green{color:green}.ubb-color-teal{color:teal}.ubb-color-blue{color:blue}.ubb-color-skyblue{color:skyblue}.ubb-color-darkblue{color:darkblue}.ubb-color-royalblue{color:royalblue}.ubb-color-purple{color:purple}.ubb-color-deeppink{color:deeppink}.ubb-color-chocolate{color:chocolate}.ubb-color-sienna{color:sienna}.ubb-color-gray{color:gray}.ubb-color-silver{color:silver}.ubb-color-white{color:white}
        .ubb-size-50{font-size:50%}.ubb-size-60{font-size:60%}.ubb-size-70{font-size:70%}.ubb-size-80{font-size:80%}.ubb-size-90{font-size:90%}.ubb-size-100{font-size:100%}.ubb-size-110{font-size:110%}.ubb-size-120{font-size:120%}.ubb-size-130{font-size:130%}.ubb-size-140{font-size:140%}.ubb-size-150{font-size:150%}.ubb-size-160{font-size:160%}.ubb-size-170{font-size:170%}.ubb-size-180{font-size:180%}.ubb-size-190{font-size:190%}.ubb-size-200{font-size:200%}
        .ubb-align-left{text-align:left}.ubb-align-center{text-align:center}.ubb-align-right{text-align:right}
        @media(max-width:700px){table,thead,tbody,tfoot{display:block;width:100%}tr{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:8px;margin:8px 0}td,th{display:block;width:auto!important;min-width:0;border-radius:6px}}@media(max-width:360px){.ubb-split-row{grid-template-columns:1fr}.ubb-split-right{text-align:left}}
        \(rendered.additionalStyleSheet)
        </style></head><body><main id="snga-post-content">\(clean)</main></body></html>
        """
        return SanitizedPost(html: html, nativeContent: nativeContent)
    }

    private func compactedPostSpacing(_ html: String) -> String {
        var output = html
        output = output.replacingOccurrences(
            of: #"^(?:\s*<br\s*/?>\s*)+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        output = output.replacingOccurrences(
            of: #"(?:\s*<br\s*/?>\s*)+(?=<blockquote\b)"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        output = output.replacingOccurrences(
            of: #"(</blockquote>)(?:\s*<br\s*/?>\s*)+"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )
        return output.replacingOccurrences(
            of: #"(?:\s*<br\s*/?>\s*)+$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private enum RemoteResourceKind {
        case attachment
        case avatar
    }

    private struct RenderedPostContent {
        let html: String
        let additionalStyleSheet: String
    }

    private struct PostStyleRegistry {
        private let prefix: String
        private var rules: [String] = []

        init(source: String) {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in source.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            prefix = "snga-fixed-\(String(hash, radix: 16))"
        }

        mutating func register(_ declarations: String, semanticClass: String? = nil) -> String {
            let generatedClass = "\(prefix)-\(rules.count)"
            rules.append(".\(generatedClass){\(declarations)}")
            if let semanticClass {
                return "\(semanticClass) \(generatedClass)"
            }
            return generatedClass
        }

        var styleSheet: String {
            rules.joined()
        }
    }

    private func renderGameCards(
        in source: String,
        topicRating: TopicRating?
    ) -> String {
        replacingMatches(
            in: source,
            pattern: #"\[randomblock\](.*?)\[/randomblock\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            let body = captures.first ?? ""
            return renderGameCard(body, topicRating: topicRating)
                ?? "[randomblock]\(body)[/randomblock]"
        }
    }

    private func renderGameCard(
        _ source: String,
        topicRating: TopicRating?
    ) -> String? {
        let title = gameCardComment("game_title_cn", in: source)
            .map(gameCardText)
            .flatMap { $0.isEmpty ? nil : $0 }
        let imageURL = gameCardComment("game_title_image", in: source)
            .flatMap(gameCardImageURL)
        guard title != nil || imageURL != nil else { return nil }

        let subtitle = gameCardComment("game_title", in: source)
            .map(gameCardText)
            .flatMap { $0.isEmpty ? nil : $0 }
        let releaseItems = gameCardComment("game_release", in: source)
            .map(gameCardReleaseItems)
            ?? []
        let fields: [(label: String, value: String)] = [
            ("游戏类型", gameCardComment("game_type", in: source)),
            (
                "开发商",
                gameCardComment("game_devloper", in: source)
                    ?? gameCardComment("game_developer", in: source)
            ),
            ("发行商", gameCardComment("game_publisher", in: source))
        ].compactMap { label, rawValue in
            guard let rawValue else { return nil }
            let value = gameCardText(rawValue)
            return value.isEmpty ? nil : (label, value)
        }
        let website = gameCardWebsite(in: source)
        let ratingDimension = topicRating?.dimensions.first
        let cardClass = ratingDimension == nil
            ? "nga-game-card nga-game-card-no-score"
            : "nga-game-card"
        var parts = [#"<section class="\#(cardClass)">"#]

        if let ratingDimension, let topicRating {
            let oneDecimalAverage = (
                ratingDimension.averageScore * 10
            ).rounded(.down) / 10
            parts.append(
                #"<div class="nga-game-score"><span class="nga-game-score-value">\#(String(format: "%.1f", oneDecimalAverage))</span><span class="nga-game-score-count">\#(topicRating.participantCount) 人评分</span></div>"#
            )
        }

        parts.append(#"<div class="nga-game-heading">"#)
        if let title {
            parts.append(#"<h3 class="nga-game-title">\#(htmlEscaped(title))</h3>"#)
        }
        if let subtitle {
            parts.append(#"<div class="nga-game-subtitle">\#(htmlEscaped(subtitle))</div>"#)
        }
        if !releaseItems.isEmpty {
            parts.append(#"<div class="nga-game-release">"#)
            for item in releaseItems {
                parts.append(
                    #"<span class="nga-game-release-item"><span class="nga-game-platform">\#(htmlEscaped(item.platform))</span><span>\#(htmlEscaped(item.date))</span></span>"#
                )
            }
            parts.append("</div>")
        }
        parts.append("</div>")

        if let imageURL {
            parts.append(
                #"<div class="nga-game-cover"><img src="\#(htmlAttributeEscaped(imageURL.absoluteString))" alt="\#(htmlAttributeEscaped(title ?? "游戏封面"))"></div>"#
            )
        }

        if !fields.isEmpty || website != nil {
            parts.append(#"<div class="nga-game-details">"#)
            for field in fields {
                parts.append(
                    #"<div class="nga-game-field"><div class="nga-game-label">\#(field.label)</div><div class="nga-game-value">\#(htmlEscaped(field.value))</div></div>"#
                )
            }
            if let website {
                parts.append(
                    #"<div class="nga-game-field nga-game-website"><div class="nga-game-label">官方网站</div><div class="nga-game-value"><a href="\#(htmlAttributeEscaped(website.url.absoluteString))">\#(htmlEscaped(website.label)) <span aria-hidden="true">↗</span></a></div></div>"#
                )
            }
            parts.append("</div>")
        }

        if let supplementaryContent = gameCardSupplementaryContent(in: source) {
            parts.append(
                #"<div class="nga-game-extra">\#(supplementaryContent)</div>"#
            )
        }

        parts.append("</section>")
        return parts.joined()
    }

    private func gameCardComment(
        _ name: String,
        in source: String
    ) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"\[comment\s+\#(escapedName)\](.*?)\[/comment\s+\#(escapedName)\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }
        let original = source as NSString
        guard let match = expression.firstMatch(
            in: source,
            range: NSRange(location: 0, length: original.length)
        ), match.numberOfRanges > 1 else {
            return nil
        }
        return original.substring(with: match.range(at: 1))
    }

    private func gameCardText(_ source: String) -> String {
        var value = source
        value = value.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(
            of: #"\[[^\]]+\]"#,
            with: " ",
            options: .regularExpression
        )
        return plainText(value)
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gameCardImageURL(_ source: String) -> URL? {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"\[style\b[^\]]*\bsrc\s+([^\s\]]+)"#,
            options: .caseInsensitive
        ) else {
            return nil
        }
        let original = source as NSString
        guard let match = expression.firstMatch(
            in: source,
            range: NSRange(location: 0, length: original.length)
        ), match.numberOfRanges > 1 else {
            return nil
        }
        return remoteResourceURL(
            original.substring(with: match.range(at: 1)),
            kind: .attachment
        )
    }

    private func gameCardReleaseItems(
        _ source: String
    ) -> [(platform: String, date: String)] {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"\[style\b[^\]]*\](.*?)\[/style\]\s*([12]\d{3}-\d{2}-\d{2})"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        let original = source as NSString
        return expression.matches(
            in: source,
            range: NSRange(location: 0, length: original.length)
        ).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let platform = gameCardText(
                original.substring(with: match.range(at: 1))
            )
            let date = original.substring(with: match.range(at: 2))
            return platform.isEmpty ? nil : (platform, date)
        }
    }

    private func gameCardWebsite(
        in source: String
    ) -> (url: URL, label: String)? {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"\[url=([^\]]+)\](.*?)\[/url\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }
        let original = source as NSString
        guard let match = expression.firstMatch(
            in: source,
            range: NSRange(location: 0, length: original.length)
        ), match.numberOfRanges > 2,
        let url = absoluteURL(
            original.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines),
            relativeTo: NGAEndpoint.baseURL
        ),
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        let securedURL = secureURL(url) ?? url
        let rawLabel = gameCardText(
            original.substring(with: match.range(at: 2))
        )
        let label = rawLabel.isEmpty
            ? securedURL.host ?? securedURL.absoluteString
            : rawLabel
        return (securedURL, label)
    }

    private func gameCardSupplementaryContent(in source: String) -> String? {
        var remaining = source
        let commentNames = [
            "game_title_cn", "game_title", "game_release", "game_title_image",
            "game_type", "game_devloper", "game_developer", "game_publisher",
            "game_website"
        ]
        for name in commentNames {
            let escapedName = NSRegularExpression.escapedPattern(for: name)
            remaining = remaining.replacingOccurrences(
                of: #"\[comment\s+\#(escapedName)\][\s\S]*?\[/comment\s+\#(escapedName)\]"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"\[color=[^\]]+\].*?\[/color\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }
        let original = remaining as NSString
        let content = expression.matches(
            in: remaining,
            range: NSRange(location: 0, length: original.length)
        ).map {
            original.substring(with: $0.range)
        }.joined(separator: " ")
        return content.isEmpty ? nil : content
    }

    private struct FixedBlockConfiguration {
        let minimumWidth: Double
        let maximumWidth: Double
        let height: Double
        let outerBackground: String
        let innerBackground: String
    }

    private func renderFixedStyleBlocks(
        in source: String,
        styles: inout PostStyleRegistry
    ) -> String {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"\[randomblock\](.*?)\[/randomblock\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return source }
        let original = source as NSString
        let matches = expression.matches(
            in: source,
            range: NSRange(location: 0, length: original.length)
        )
        guard !matches.isEmpty else { return source }

        var result = ""
        var cursor = 0
        var matchIndex = 0
        while matchIndex < matches.count {
            let firstMatch = matches[matchIndex]
            var alternatives = [firstMatch]
            var groupEnd = NSMaxRange(firstMatch.range)
            var nextIndex = matchIndex + 1

            while nextIndex < matches.count {
                let nextMatch = matches[nextIndex]
                let separatorRange = NSRange(
                    location: groupEnd,
                    length: nextMatch.range.location - groupEnd
                )
                guard isRandomBlockSeparator(original.substring(with: separatorRange)) else {
                    break
                }
                alternatives.append(nextMatch)
                groupEnd = NSMaxRange(nextMatch.range)
                nextIndex += 1
            }

            result += original.substring(
                with: NSRange(
                    location: cursor,
                    length: firstMatch.range.location - cursor
                )
            )
            let rawAlternatives = alternatives.map { original.substring(with: $0.range) }
            var renderedAlternatives: [String?] = []
            renderedAlternatives.reserveCapacity(alternatives.count)
            for alternative in alternatives {
                let body = alternative.numberOfRanges > 1
                    ? original.substring(with: alternative.range(at: 1))
                    : ""
                renderedAlternatives.append(renderFixedStyleBlock(body, styles: &styles))
            }

            if alternatives.count > 1,
               renderedAlternatives.allSatisfy({ $0 != nil }) {
                result += renderFixedStyleCarousel(
                    renderedAlternatives.compactMap { $0 },
                    selectedIndex: stableRandomBlockIndex(in: rawAlternatives)
                )
            } else {
                for alternativeIndex in alternatives.indices {
                    if alternativeIndex > 0 {
                        let previousMatch = alternatives[alternativeIndex - 1]
                        let currentMatch = alternatives[alternativeIndex]
                        result += original.substring(
                            with: NSRange(
                                location: NSMaxRange(previousMatch.range),
                                length: currentMatch.range.location - NSMaxRange(previousMatch.range)
                            )
                        )
                    }
                    result += renderedAlternatives[alternativeIndex]
                        ?? rawAlternatives[alternativeIndex]
                }
            }
            cursor = groupEnd
            matchIndex = nextIndex
        }
        result += original.substring(from: cursor)
        return result
    }

    private func renderFixedStyleCarousel(
        _ alternatives: [String],
        selectedIndex: Int
    ) -> String {
        let count = alternatives.count
        let panels = alternatives.enumerated().map { index, html in
            let isSelected = index == selectedIndex
            let stateClass = isSelected ? " snga-is-active" : ""
            return #"<div class="nga-random-block-panel\#(stateClass)" aria-hidden="\#(!isSelected)">\#(html)</div>"#
        }.joined()
        let buttons = alternatives.indices.map { index in
            let isSelected = index == selectedIndex
            let stateClass = isSelected ? " snga-is-active" : ""
            return #"<button type="button" class="nga-random-block-button\#(stateClass)" data-snga-random-block-index="\#(index)" aria-label="显示版头 \#(index + 1)，共 \#(count) 个" aria-pressed="\#(isSelected)"></button>"#
        }.joined()
        return #"<div class="nga-random-block-carousel" role="group" aria-label="版头内容">\#(panels)<div class="nga-random-block-controls" role="group" aria-label="切换版头">\#(buttons)</div></div>"#
    }

    private func renderFixedStyleBlock(
        _ source: String,
        styles: inout PostStyleRegistry
    ) -> String? {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"\[fixsize\s+([^\]]+)\]"#,
            options: .caseInsensitive
        ) else { return nil }
        let original = source as NSString
        guard let match = expression.firstMatch(
            in: source,
            range: NSRange(location: 0, length: original.length)
        ), match.numberOfRanges > 1,
        let configuration = fixedBlockConfiguration(
            original.substring(with: match.range(at: 1))
        ) else { return nil }

        var body = source
        if let range = Range(match.range, in: body) {
            body.removeSubrange(range)
        }
        body = body.replacingOccurrences(
            of: #"\[/?fixsize(?:\s+[^\]]*)?\]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        body = compactFixedStyleLayout(body)
        body = renderFixedStyleMarkup(in: body, styles: &styles)

        let height = cssNumber(configuration.height)
        let minimumWidth = cssNumber(configuration.minimumWidth)
        let maximumWidth = cssNumber(configuration.maximumWidth)
        let outerClass = styles.register(
            "clear:both;overflow:hidden;width:auto;height:\(height)em;background:\(configuration.outerBackground);",
            semanticClass: "nga-fixed-block"
        )
        let innerClass = styles.register(
            "margin:auto;overflow:hidden;position:relative;z-index:0;height:\(height)em;max-width:\(maximumWidth)em;min-width:\(minimumWidth)em;background:\(configuration.innerBackground);",
            semanticClass: "nga-fixed-block-canvas"
        )
        return #"<div class="\#(outerClass)"><div class="\#(innerClass)">\#(body)</div></div>"#
    }

    private func compactFixedStyleLayout(_ source: String) -> String {
        var output = removingStripBreakMarkers(from: source)
        output = output.replacingOccurrences(
            of: #"\[/?comment(?:\s+[^\]]*)?\](?:[ \t\r\n]*<br\s*/?>)?"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let layoutTag = #"\[(?:/?style(?:\s+[^\]]*)?|/?url(?:=[^\]]*)?|/?randomblock)\]"#
        output = output.replacingOccurrences(
            of: #"(\#(layoutTag))(?:(?:[ \t\r\n]*<br\s*/?>[ \t\r\n]*)+|[ \t\r\n]+)(?=\#(layoutTag))"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )
        output = output.replacingOccurrences(
            of: #"(?:[ \t\r\n]*<br\s*/?>[ \t\r\n]*)+$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removingStripBreakMarkers(from source: String) -> String {
        source.replacingOccurrences(
            of: #"\[/?stripbr\][ \t]*(?:<br\s*/?>|\r?\n)?"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func renderFixedStyleMarkup(
        in source: String,
        styles: inout PostStyleRegistry
    ) -> String {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"\[style(?:\s+[^\]]*)?\]|\[/style\]"#,
            options: .caseInsensitive
        ) else { return source }
        let original = source as NSString
        let matches = expression.matches(
            in: source,
            range: NSRange(location: 0, length: original.length)
        )
        var result = ""
        var cursor = 0
        var openElements: [Bool] = []

        for match in matches {
            result += original.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            let token = original.substring(with: match.range)
            if token.lowercased().hasPrefix("[/style") {
                if openElements.popLast() == true {
                    result += "</div>"
                }
            } else {
                let attributes = String(token.dropFirst("[style".count).dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let className = styles.register(fixedStyleDeclarations(attributes))
                if let imageURL = fixedStyleImageURL(attributes) {
                    result += #"<img class="\#(className)" src="\#(htmlAttributeEscaped(imageURL.absoluteString))" alt="帖子图片">"#
                    openElements.append(false)
                } else {
                    result += #"<div class="\#(className)">"#
                    openElements.append(true)
                }
            }
            cursor = NSMaxRange(match.range)
        }
        result += original.substring(from: cursor)
        for shouldClose in openElements.reversed() where shouldClose {
            result += "</div>"
        }
        return result
    }

    private func fixedStyleImageURL(_ source: String) -> URL? {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"(?:^|\s)src\s+([^\s]+)"#,
            options: .caseInsensitive
        ) else { return nil }
        let original = source as NSString
        guard let match = expression.firstMatch(
            in: source,
            range: NSRange(location: 0, length: original.length)
        ), match.numberOfRanges > 1 else { return nil }
        return remoteResourceURL(
            original.substring(with: match.range(at: 1)),
            kind: .attachment
        )
    }

    private func fixedBlockConfiguration(_ source: String) -> FixedBlockConfiguration? {
        let tokens = source.split(whereSeparator: \.isWhitespace).map(String.init)
        let lowered = tokens.map { $0.lowercased() }
        guard let widthIndex = lowered.firstIndex(of: "width"),
              tokens.indices.contains(widthIndex + 1),
              let firstWidth = Double(tokens[widthIndex + 1]),
              firstWidth.isFinite,
              firstWidth > 0,
              firstWidth <= 5_000,
              let heightIndex = lowered.firstIndex(of: "height"),
              tokens.indices.contains(heightIndex + 1),
              let height = Double(tokens[heightIndex + 1]),
              height.isFinite,
              height > 0,
              height <= 5_000 else {
            return nil
        }
        let secondWidth = tokens.indices.contains(widthIndex + 2)
            ? Double(tokens[widthIndex + 2])
            : nil
        let maximumWidth = min(5_000, max(firstWidth, secondWidth ?? firstWidth))
        let minimumWidth = min(firstWidth, maximumWidth)

        var backgrounds = ["#000000", "#dddddd"]
        if let backgroundIndex = lowered.firstIndex(of: "background") {
            let candidates = tokens.dropFirst(backgroundIndex + 1).prefix(2)
                .compactMap(safeCSSColor)
            if let first = candidates.first {
                backgrounds[0] = first
                backgrounds[1] = candidates.count > 1 ? candidates[1] : first
            }
        }
        return FixedBlockConfiguration(
            minimumWidth: minimumWidth,
            maximumWidth: maximumWidth,
            height: height,
            outerBackground: backgrounds[0],
            innerBackground: backgrounds[1]
        )
    }

    private func fixedStyleDeclarations(_ source: String) -> String {
        let supportedKeys = Set([
            "width", "height", "left", "right", "top", "bottom",
            "line-height", "font", "color", "background", "rotate",
            "dybg", "filter-drop-shadow", "src", "padding"
        ])
        let tokens = source.split(whereSeparator: \.isWhitespace).map(String.init)
        var attributes: [String: String] = [:]
        var index = 0
        while index + 1 < tokens.count {
            let key = tokens[index].lowercased()
            if supportedKeys.contains(key) {
                if key == "padding" {
                    var values = [tokens[index + 1]]
                    if tokens.indices.contains(index + 2),
                       !supportedKeys.contains(tokens[index + 2].lowercased()),
                       safeCSSLength(tokens[index + 2]) != nil {
                        values.append(tokens[index + 2])
                    }
                    attributes[key] = values.joined(separator: " ")
                    index += values.count + 1
                } else {
                    attributes[key] = tokens[index + 1]
                    index += 2
                }
            } else {
                index += 1
            }
        }

        var declarations = ["display:inline-block"]
        let lengthKeys = ["width", "height", "left", "right", "top", "bottom"]
        for key in lengthKeys {
            if let rawValue = attributes[key], let value = safeCSSLength(rawValue) {
                declarations.append("\(key):\(value)")
            }
        }
        let positionKeys = ["left", "right", "top", "bottom"]
        if positionKeys.contains(where: { attributes[$0] != nil }) {
            declarations.append("position:absolute")
        }
        if let rawPadding = attributes["padding"] {
            let values = rawPadding.split(whereSeparator: \.isWhitespace)
                .compactMap { safeCSSLength(String($0)) }
            if !values.isEmpty {
                declarations.append("padding:\(values.joined(separator: " "))")
            }
        }
        if let rawValue = attributes["line-height"], let value = safeCSSLength(rawValue) {
            declarations.append("line-height:\(value)")
        }
        if let rawValue = attributes["font"],
           let value = Double(rawValue), value.isFinite, (0.5...3).contains(value) {
            declarations.append("font-size:\(cssNumber(value))em")
        }
        if let color = attributes["color"].flatMap(safeCSSColor) {
            declarations.append("color:\(color)")
        }
        if let background = attributes["background"].flatMap(safeCSSColor) {
            declarations.append("background:\(background)")
        }
        if let rawValue = attributes["rotate"],
           let degrees = Double(rawValue), degrees.isFinite, abs(degrees) <= 3_600 {
            declarations.append("transform:rotate(\(cssNumber(degrees))deg)")
        }
        if let dybg = attributes["dybg"] {
            declarations.append(contentsOf: fixedBackgroundDeclarations(dybg))
        }
        if let shadow = attributes["filter-drop-shadow"].flatMap(fixedDropShadow) {
            declarations.append("filter:\(shadow)")
        }
        return declarations.joined(separator: ";") + ";"
    }

    private func fixedBackgroundDeclarations(_ source: String) -> [String] {
        let components = source.split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count >= 6 else { return [] }
        var declarations: [String] = []
        if let url = remoteResourceURL(components[5], kind: .attachment) {
            declarations.append("background-image:url(\"\(url.absoluteString)\")")
        }
        if let size = safeCSSLength(components[0], defaultUnit: "%") {
            declarations.append("background-size:\(size)")
        }
        if let horizontal = safeCSSLength(components[1], defaultUnit: "%"),
           let vertical = safeCSSLength(components[2], defaultUnit: "%") {
            declarations.append("background-position:\(horizontal) \(vertical)")
        }
        return declarations
    }

    private func fixedDropShadow(_ source: String) -> String? {
        let components = source.split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count == 4,
              let color = safeCSSColor(components[0]),
              let x = safeCSSLength(components[1]),
              let y = safeCSSLength(components[2]),
              let blur = safeCSSLength(components[3]) else {
            return nil
        }
        return "drop-shadow(\(x) \(y) \(blur) \(color))"
    }

    private func safeCSSLength(_ source: String, defaultUnit: String = "em") -> String? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(
            of: #"^-?\d+(?:\.\d+)?%?$"#,
            options: .regularExpression
        ) != nil else { return nil }
        let hasPercent = value.hasSuffix("%")
        let numericText = hasPercent ? String(value.dropLast()) : value
        guard let number = Double(numericText), number.isFinite, abs(number) <= 5_000 else {
            return nil
        }
        return "\(cssNumber(number))\(hasPercent ? "%" : defaultUnit)"
    }

    private func safeCSSColor(_ source: String) -> String? {
        let value = source.lowercased()
        guard value.range(
            of: #"^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return value
    }

    private func cssNumber(_ value: Double) -> String {
        guard value.rounded() != value else { return String(Int(value)) }
        return String(value)
    }

    private func isRandomBlockSeparator(_ source: String) -> Bool {
        source.range(
            of: #"^(?:(?:\s|<br\s*/?>)|\[/?stripbr\])*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func stableRandomBlockIndex(in alternatives: [String]) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for alternative in alternatives {
            for byte in alternative.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xFF
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(alternatives.count))
    }

    private func renderBBCode(
        _ source: String,
        topicRating: TopicRating?
    ) -> RenderedPostContent {
        var styleRegistry = PostStyleRegistry(source: source)
        var output = renderGameCards(in: source, topicRating: topicRating)
        output = renderFixedStyleBlocks(in: output, styles: &styleRegistry)
        output = removingStripBreakMarkers(from: output)

        output = output.replacingOccurrences(
            of: "[randomblock]",
            with: #"<section class="nga-rich-card">"#,
            options: .caseInsensitive
        )
        output = output.replacingOccurrences(
            of: "[/randomblock]",
            with: "</section>",
            options: .caseInsensitive
        )
        output = output.replacingOccurrences(
            of: "[comment game_title_cn]",
            with: #"<h3 class="nga-rich-card-title">"#,
            options: .caseInsensitive
        )
        output = output.replacingOccurrences(
            of: "[/comment game_title_cn]",
            with: "</h3>",
            options: .caseInsensitive
        )
        output = output.replacingOccurrences(
            of: "[comment game_title_image]",
            with: #"<div class="nga-rich-card-image">"#,
            options: .caseInsensitive
        )
        output = output.replacingOccurrences(
            of: "[/comment game_title_image]",
            with: "</div>",
            options: .caseInsensitive
        )
        output = replacingMatches(
            in: output,
            pattern: #"\[style\b[^\]]*\bsrc\s+([^\s\]]+)[^\]]*\]\s*\[/style\]"#,
            options: [.caseInsensitive]
        ) { captures in
            let raw = captures.first ?? ""
            guard let url = remoteResourceURL(raw, kind: .attachment) else {
                return ""
            }
            return #"<img src="\#(htmlAttributeEscaped(url.absoluteString))" alt="帖子图片">"#
        }
        output = output.replacingOccurrences(
            of: #"\[style\b[^\]]*\binnerHTML\s+[^\s\]]+[^\]]*\]"#,
            with: "—",
            options: [.regularExpression, .caseInsensitive]
        )
        output = output.replacingOccurrences(
            of: #"\[(?:/?fixsize(?:\s+[^\]]*)?|/?style(?:\s+[^\]]*)?|comment(?:\s+[^\]]*)?|/comment(?:\s+[^\]]*)?)\]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        output = replacingMatches(
            in: output,
            pattern: #"\[size=0%\].*?\[/size\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { _ in "" }

        output = replacingMatches(
            in: output,
            pattern: #"\[tid=(\d+)\][^\[]*\[/tid\]\s*(?:\*\*|\[b\])?\s*Post by\s+(?:\[uid=[^\]]+\])?(.+?)(?:\[/uid\])?\s*(\([^)]+\):?)(?:\*\*|\[/b\])?"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            guard captures.count == 3 else { return "" }
            let target = "https://bbs.nga.cn/read.php?tid=\(captures[0])"
            let username = htmlEscaped(captures[1].trimmingCharacters(in: .whitespacesAndNewlines))
            let timestamp = htmlEscaped(captures[2])
            return #"<a class="nga-post-reference" href="\#(target)">Post by \#(username) \#(timestamp)</a>"#
        }

        output = replacingMatches(
            in: output,
            pattern: #"\[tid=(\d+)\](.*?)\[/tid\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            guard captures.count == 2 else { return "" }
            let target = "https://bbs.nga.cn/read.php?tid=\(captures[0])"
            return #"<a class="nga-post-reference" href="\#(target)">\#(captures[1])</a>"#
        }

        output = replacingMatches(
            in: output,
            pattern: #"\[pid=(\d+)(?:,(\d+))?(?:,(\d+))?\][^\[]*\[/pid\]\s*(?:\*\*|\[b\])?\s*Post by\s+\[uid=[^\]]+\](.*?)\[/uid\]\s*(\([^)]+\):)(?:\*\*|\[/b\])?"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            guard captures.count == 5 else { return "" }
            var components = URLComponents(url: NGAEndpoint.baseURL.appending(path: "/read.php"), resolvingAgainstBaseURL: false)!
            var queryItems = [URLQueryItem(name: "pid", value: captures[0])]
            if !captures[1].isEmpty {
                queryItems.append(URLQueryItem(name: "tid", value: captures[1]))
            }
            if !captures[2].isEmpty {
                queryItems.append(URLQueryItem(name: "page", value: captures[2]))
            }
            components.queryItems = queryItems
            let target = components.url?.absoluteString ?? "https://bbs.nga.cn/read.php?pid=\(captures[0])"
            let username = htmlEscaped(captures[3].trimmingCharacters(in: .whitespacesAndNewlines))
            let timestamp = htmlEscaped(captures[4])
            return #"<a class="nga-post-reference" href="\#(htmlAttributeEscaped(target))">Post by \#(username) \#(timestamp)</a>"#
        }

        output = replacingMatches(
            in: output,
            pattern: #"\[pid=(\d+)(?:,[^\]]*)?\](.*?)\[/pid\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            guard captures.count == 2 else { return "" }
            let target = "https://bbs.nga.cn/read.php?pid=\(captures[0])"
            return #"<a class="nga-post-reference" href="\#(target)">\#(captures[1])</a>"#
        }

        output = replacingMatches(
            in: output,
            pattern: #"\[uid=[^\]]+\](.*?)\[/uid\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            captures.first ?? ""
        }

        output = replacingMatches(
            in: output,
            pattern: #"\[s:([a-zA-Z0-9]+):([^\]]+)\]"#
        ) { captures in
            guard captures.count == 2,
                  let file = smileFile(family: captures[0], name: captures[1]) else {
                return htmlEscaped(captures.last ?? "表情")
            }
            let url = "https://img4.nga.cn/ngabbs/post/smile/\(file)"
            return #"<img class="nga-smile" src="\#(url)" alt="\#(htmlAttributeEscaped(captures[1]))">"#
        }

        output = replacingMatches(
            in: output,
            pattern: #"\[img(?:=[^\]]*)?\](.*?)\[/img\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            let raw = captures.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let url = remoteResourceURL(raw, kind: .attachment) else {
                return htmlEscaped(raw)
            }
            return #"<img src="\#(htmlAttributeEscaped(url.absoluteString))" alt="帖子图片">"#
        }

        output = replacingMatches(
            in: output,
            pattern: #"\[url=([^\]]+)\](.*?)\[/url\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            guard captures.count == 2,
                  let url = absoluteURL(
                    captures[0].trimmingCharacters(in: .whitespacesAndNewlines),
                    relativeTo: NGAEndpoint.baseURL
                  ),
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
                return captures.last ?? ""
            }
            return #"<a href="\#(htmlAttributeEscaped(secureURL(url)?.absoluteString ?? url.absoluteString))">\#(captures[1])</a>"#
        }

        output = replacingMatches(
            in: output,
            pattern: #"\[url\](.*?)\[/url\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            let raw = captures.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let url = absoluteURL(raw, relativeTo: NGAEndpoint.baseURL),
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
                return htmlEscaped(raw)
            }
            let target = secureURL(url)?.absoluteString ?? url.absoluteString
            return #"<a href="\#(htmlAttributeEscaped(target))">\#(htmlEscaped(raw))</a>"#
        }

        output = replacingMatches(
            in: output,
            pattern: #"\[code\](.*?)\[/code\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            "<pre><code>\(htmlEscaped(captures.first ?? ""))</code></pre>"
        }
        output = replacingMatches(
            in: output,
            pattern: #"\[collapse(?:=([^\]]*))?\](.*?)\[/collapse\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            let title = captures.first.flatMap { $0.isEmpty ? nil : $0 } ?? "折叠内容"
            let body = captures.count > 1 ? captures[1] : ""
            return "<details><summary>\(htmlEscaped(title))</summary>\(body)</details>"
        }
        output = renderQuoteBBCode(output)
        output = renderListBBCode(output)
        output = renderDirectionalBBCode(output)
        output = renderTableBBCode(output)

        let pairedTags: [(String, String)] = [
            ("b", "strong"), ("i", "em"), ("u", "u"), ("s", "strike"),
            ("del", "strike"), ("sup", "sup")
        ]
        for (bbcode, htmlTag) in pairedTags {
            output = output.replacingOccurrences(
                of: "[\(bbcode)]",
                with: "<\(htmlTag)>",
                options: .caseInsensitive
            )
            output = output.replacingOccurrences(
                of: "[/\(bbcode)]",
                with: "</\(htmlTag)>",
                options: .caseInsensitive
            )
        }

        output = replacingMatches(
            in: output,
            pattern: #"\[color=([^\]]+)\]"#,
            options: [.caseInsensitive]
        ) { captures in
            let supported = [
                "red", "orange", "orangered", "green", "teal", "blue",
                "skyblue", "darkblue", "royalblue", "purple", "deeppink",
                "chocolate", "sienna", "gray", "silver", "white"
            ]
            let value = captures.first?.lowercased() ?? ""
            let color = supported.contains(value) ? value : "default"
            return #"<span class="ubb-color-\#(color)">"#
        }
        output = output.replacingOccurrences(
            of: "[/color]",
            with: "</span>",
            options: .caseInsensitive
        )
        output = replacingMatches(
            in: output,
            pattern: #"\[size=(\d{1,3})%\]"#,
            options: [.caseInsensitive]
        ) { captures in
            let value = Int(captures.first ?? "").map { min(200, max(50, $0)) } ?? 100
            let rounded = ((value + 5) / 10) * 10
            return #"<span class="ubb-size-\#(rounded)">"#
        }
        output = output.replacingOccurrences(
            of: "[/size]",
            with: "</span>",
            options: .caseInsensitive
        )
        output = replacingMatches(
            in: output,
            pattern: #"\[align=(left|center|right)\]"#,
            options: [.caseInsensitive]
        ) { captures in
            #"<div class="ubb-align-\#(captures.first?.lowercased() ?? "left")">"#
        }
        output = output.replacingOccurrences(
            of: "[/align]",
            with: "</div>",
            options: .caseInsensitive
        )
        output = output.replacingOccurrences(
            of: #"\[(?:color|size|font|align)=[^\]]+\]"#,
            with: "<span>",
            options: [.regularExpression, .caseInsensitive]
        )
        output = output.replacingOccurrences(
            of: #"\[/(?:color|size|font|align)\]"#,
            with: "</span>",
            options: [.regularExpression, .caseInsensitive]
        )
        output = replacingMatches(
            in: output,
            pattern: #"(^|<br\s*/?>|\n)\s*={3,}\s*((?:(?!<br\s*/?>|\n|={3,}).)+?)\s*={3,}\s*(?=<br\s*/?>|\n|$)"#,
            options: [.caseInsensitive]
        ) { captures in
            guard captures.count == 2 else { return "" }
            let title = captures[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return #"\#(captures[0])<h3 class="nga-section-title">\#(title)</h3>"#
        }
        output = replacingMatches(
            in: output,
            pattern: #"(^|<br\s*/?>|\n)\s*={3,}\s*(<br\s*/?>|\n|$)"#,
            options: [.caseInsensitive]
        ) { _ in
            "<hr>"
        }
        output = output.replacingOccurrences(of: "\r\n", with: "\n")
        output = output.replacingOccurrences(of: "\r", with: "\n")
        output = output.replacingOccurrences(of: "\n", with: "<br>")
        let html = output.replacingOccurrences(
            of: #"(?i)(?:\s*<br\s*/?>\s*){3,}"#,
            with: "<br><br>",
            options: .regularExpression
        )
        return RenderedPostContent(
            html: html,
            additionalStyleSheet: styleRegistry.styleSheet
        )
    }

    private func renderDirectionalBBCode(_ source: String) -> String {
        var output = replacingMatches(
            in: source,
            pattern: #"\[l\]((?:(?!\[/l\]).)*)\[/l\]\s*\[r\]((?:(?!\[/r\]).)*)\[/r\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            guard captures.count == 2 else { return "" }
            return #"<div class="ubb-split-row"><div class="ubb-split-left">\#(captures[0])</div><div class="ubb-split-right">\#(captures[1])</div></div>"#
        }
        let directionalTags = [
            ("l", "ubb-align-left"),
            ("c", "ubb-align-center"),
            ("r", "ubb-align-right")
        ]
        for (tag, cssClass) in directionalTags {
            output = replacingMatches(
                in: output,
                pattern: #"\[\#(tag)\]((?:(?!\[/\#(tag)\]).)*)\[/\#(tag)\]"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) { captures in
                #"<div class="\#(cssClass)">\#(captures.first ?? "")</div>"#
            }
        }
        return output
    }

    /// `[quote]...[/quote]` 转 `<blockquote>`。
    ///
    /// 引用是可以套引用的（引用的那层自己也带着上一层的引用），所以不能用
    /// `\[quote\](.*?)\[/quote\]` 这种非贪婪匹配去配对：它会拿最里面的
    /// `[/quote]` 去闭合最外面的 `[quote]`，剩下的标记原样漏进正文，读者看到的
    /// 就是满屏的 `[quote]`。这里按栈配对，只有真正成对的标记才会成块。
    ///
    /// 落单的标记（跨页截断、作者手写错）保持字面量，不吞掉任何正文。
    private func renderQuoteBBCode(_ source: String) -> String {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"\[quote[^\]]*\]|\[/quote\]"#,
            options: [.caseInsensitive]
        ) else {
            return source
        }
        let original = source as NSString
        let matches = expression.matches(
            in: source,
            range: NSRange(location: 0, length: original.length)
        )
        guard !matches.isEmpty else { return source }

        // 每一层未闭合的引用占一格：`openings` 是它的开标记原文，`levels` 是
        // 已经收集到的内容。栈底那格是最终输出，没有对应的开标记。
        var openings: [String] = []
        var levels: [String] = [""]
        var cursor = 0

        func appendToCurrentLevel(_ text: String) {
            levels[levels.count - 1] += text
        }

        for match in matches {
            let token = original.substring(with: match.range)
            appendToCurrentLevel(
                original.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
            )
            cursor = match.range.location + match.range.length

            guard token.hasPrefix("[/") else {
                openings.append(token)
                levels.append("")
                continue
            }
            guard !openings.isEmpty else {
                // 没有开标记可配对，这个 `[/quote]` 只是一段普通文字。
                appendToCurrentLevel(token)
                continue
            }
            openings.removeLast()
            let quoted = levels.removeLast()
            appendToCurrentLevel("<blockquote>\(quoted)</blockquote>")
        }
        appendToCurrentLevel(original.substring(from: cursor))

        // 还开着的层：把开标记和它收集到的内容原样还回去。
        while let opening = openings.popLast() {
            let unclosed = levels.removeLast()
            appendToCurrentLevel(opening + unclosed)
        }
        return levels[0]
    }

    private func renderTableBBCode(_ source: String) -> String {
        replacingMatches(
            in: source,
            pattern: #"\[table(?:\s+[^\]]*)?\](.*?)\[/table\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { tableCaptures in
            let body = tableCaptures.first ?? ""
            let rows = replacingMatches(
                in: body,
                pattern: #"\[tr(?:\s+[^\]]*)?\](.*?)\[/tr\]"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) { rowCaptures in
                let row = rowCaptures.first ?? ""
                let widths = tableCellWidths(in: row)
                let explicitWidths = widths.compactMap { $0 }
                let usesWeightedWidths = !widths.isEmpty
                    && explicitWidths.count == widths.count
                let totalWidth = explicitWidths.reduce(0, +)
                var renderedRow = replacingMatches(
                    in: row,
                    pattern: #"\[(td|th)(\d+(?:\.\d+)?)?(?:\s+([^\]]*))?\](.*?)\[/\1\]"#,
                    options: [.caseInsensitive, .dotMatchesLineSeparators]
                ) { cellCaptures in
                    guard cellCaptures.count == 4 else { return "" }
                    let tag = cellCaptures[0].lowercased()
                    let attributes = cellCaptures[2]
                    let width = tableCellWidth(
                        shorthand: cellCaptures[1],
                        attributes: attributes
                    )
                    var safeAttributes = ""
                    if usesWeightedWidths, let width, totalWidth > 0 {
                        let percentage = width / totalWidth * 100
                        safeAttributes += #" width="\#(formattedPercentage(percentage))%""#
                    }
                    for name in ["colspan", "rowspan"] {
                        if let span = tableCellSpan(named: name, in: attributes) {
                            safeAttributes += " \(name)=\"\(span)\""
                        }
                    }
                    return "<\(tag)\(safeAttributes)>\(cellCaptures[3])</\(tag)>"
                }
                renderedRow = renderedRow.replacingOccurrences(
                    of: #"(?i)(</?(?:td|th)\b[^>]*>)\s*(?:<br\s*/?>\s*)+(?=</?(?:td|th)\b)"#,
                    with: "$1",
                    options: .regularExpression
                )
                renderedRow = renderedRow.replacingOccurrences(
                    of: #"(?i)^(?:\s*<br\s*/?>\s*)+|(?:\s*<br\s*/?>\s*)+$"#,
                    with: "",
                    options: .regularExpression
                )
                return "<tr>\(renderedRow)</tr>"
            }
            var cleanedRows = rows.replacingOccurrences(
                of: #"(?i)(</?tr\b[^>]*>)\s*(?:<br\s*/?>\s*)+(?=</?tr\b)"#,
                with: "$1",
                options: .regularExpression
            )
            cleanedRows = cleanedRows.replacingOccurrences(
                of: #"(?i)^(?:\s*<br\s*/?>\s*)+|(?:\s*<br\s*/?>\s*)+$"#,
                with: "",
                options: .regularExpression
            )
            return "<table>\(cleanedRows)</table>"
        }
    }

    private func tableCellWidths(in row: String) -> [Double?] {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"\[(?:td|th)(\d+(?:\.\d+)?)?(?:\s+([^\]]*))?\]"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let source = row as NSString
        return expression.matches(
            in: row,
            range: NSRange(location: 0, length: source.length)
        ).map { match in
            let shorthand = match.range(at: 1).location == NSNotFound
                ? ""
                : source.substring(with: match.range(at: 1))
            let attributes = match.range(at: 2).location == NSNotFound
                ? ""
                : source.substring(with: match.range(at: 2))
            return tableCellWidth(shorthand: shorthand, attributes: attributes)
        }
    }

    private func tableCellWidth(
        shorthand: String,
        attributes: String
    ) -> Double? {
        if let width = Double(shorthand), width > 0 {
            return width
        }
        return tableCellWidth(in: attributes)
    }

    private func tableCellWidth(in attributes: String) -> Double? {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"(?:^|\s)width\s*=\s*["']?(\d+(?:\.\d+)?)"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let source = attributes as NSString
        guard let match = expression.firstMatch(
            in: attributes,
            range: NSRange(location: 0, length: source.length)
        ), match.numberOfRanges > 1 else {
            return nil
        }
        return Double(source.substring(with: match.range(at: 1)))
    }

    private func tableCellSpan(named name: String, in attributes: String) -> Int? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"(?:^|\s)\#(escapedName)\s*=\s*["']?(\d+)"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let source = attributes as NSString
        guard let match = expression.firstMatch(
            in: attributes,
            range: NSRange(location: 0, length: source.length)
        ), match.numberOfRanges > 1,
              let value = Int(source.substring(with: match.range(at: 1))) else {
            return nil
        }
        return min(12, max(1, value))
    }

    private func formattedPercentage(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.01 {
            return String(Int(rounded))
        }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private func renderListBBCode(_ source: String) -> String {
        var output = source
        let pattern = #"\[list(?:=([^\]]+))?\]((?:(?!\[list(?:=|\])).)*?)\[/list\]"#

        // 每轮只处理最内层列表，兼容正文中可能出现的嵌套列表。
        for _ in 0..<8 {
            let rendered = replacingMatches(
                in: output,
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) { captures in
                guard captures.count == 2 else { return "" }
                let style = captures[0].trimmingCharacters(in: .whitespacesAndNewlines)
                var body = captures[1]
                var hasItem = false
                body = replacingMatches(
                    in: body,
                    pattern: #"\[\*\]"#,
                    options: [.caseInsensitive]
                ) { _ in
                    defer { hasItem = true }
                    return hasItem ? "</li><li>" : "<li>"
                }

                let tag = style.isEmpty ? "ul" : "ol"
                if hasItem {
                    return "<\(tag)>\(body)</li></\(tag)>"
                }
                return "<\(tag)>\(body)</\(tag)>"
            }
            guard rendered != output else { break }
            output = rendered
        }
        return output
    }

    private func forum(
        from dictionary: [String: Any],
        category: String? = nil,
        iconPrefix: String? = nil
    ) -> Forum? {
        let forumID: ForumID
        if let stid = int64(dictionary["stid"]), stid > 0 {
            forumID = ForumID(stid: stid)
        } else if let fid = int64(dictionary["fid"]) {
            forumID = ForumID(rawValue: fid)
        } else {
            return nil
        }

        guard let rawName = string(dictionary["name"]) ?? string(dictionary["fname"]) else {
            return nil
        }
        let name = plainText(rawName)
        guard !name.isEmpty else { return nil }

        let iconURL = resolvedForumIcon(
            dictionary: dictionary,
            forumID: forumID,
            iconPrefix: iconPrefix
        )
        return Forum(
            id: forumID,
            name: name,
            subtitle: (string(dictionary["info"]) ?? string(dictionary["description"]))
                .map(plainText),
            iconURL: iconURL,
            category: category ?? string(dictionary["group"]),
            pinnedTopicID: pinnedTopicID(in: dictionary),
            isSelectedInParent: selectedSubforumState(from: dictionary)
        )
    }

    private func pinnedTopicID(in dictionary: [String: Any]) -> TopicID? {
        for key in ["topped_topic", "top_topic", "pinned_topic"] {
            if let rawValue = int64(dictionary[key]), rawValue > 0 {
                return TopicID(rawValue: rawValue)
            }
        }
        return nil
    }

    private func profile(
        from dictionary: [String: Any],
        expectedUID: Int64?
    ) -> Profile? {
        guard let uid = int64(dictionary["uid"]) ?? int64(dictionary["id"]),
              expectedUID == nil || uid == expectedUID,
              let name = string(dictionary["username"]) ?? string(dictionary["name"]),
              !name.isEmpty else {
            return nil
        }
        let masked = name == "UID\(uid)"
        return Profile(
            uid: uid,
            displayName: masked ? "NGA \(uid)" : plainText(name),
            avatarURL: remoteResourceURL(string(dictionary["avatar"]), kind: .avatar),
            userGroup: nonEmptyString(dictionary["group"]),
            title: nonEmptyString(dictionary["title"]),
            honor: nonEmptyString(dictionary["honor"]),
            registeredAt: date(dictionary["regdate"]),
            postCount: int(dictionary["posts"]),
            location: nonEmptyString(dictionary["ipLoc"]),
            signature: nonEmptyString(dictionary["sign"]).map(plainText),
            reputation: int(dictionary["rvrc"]).map { Double($0) / 10 },
            fame: int(dictionary["fame"]),
            money: int(dictionary["money"]),
            followerCount: int(dictionary["follow_by_num"]),
            isMasked: masked
        )
    }

    private func resolvedForumIcon(
        dictionary: [String: Any],
        forumID: ForumID,
        iconPrefix: String?
    ) -> URL? {
        if let value = string(dictionary["icon"]), !value.isEmpty {
            if let absolute = URL(string: value), absolute.scheme != nil {
                return secureURL(absolute)
            }
            if let iconPrefix,
               let resolved = URL(string: value, relativeTo: URL(string: iconPrefix))?.absoluteURL {
                return secureURL(resolved)
            }
        }
        guard let iconPrefix else { return nil }
        let iconID = string(dictionary["id"]) ?? forumID.description
        guard var components = URLComponents(string: "\(iconPrefix)\(iconID).png") else { return nil }
        if components.scheme == "http" { components.scheme = "https" }
        return components.url.flatMap(secureURL)
    }

    private func secureURL(_ value: URL) -> URL? {
        let host = value.host?.lowercased()
        guard value.scheme == "http" || host == "img.nga.178.com" || host == "img4.nga.178.com" else {
            return value
        }
        var components = URLComponents(url: value, resolvingAgainstBaseURL: false)
        if value.scheme == "http" { components?.scheme = "https" }
        if host == "img.nga.178.com" { components?.host = "img.nga.cn" }
        if host == "img4.nga.178.com" { components?.host = "img4.nga.cn" }
        return components?.url
    }

    private func parseTopic(from dictionary: [String: Any], fallbackForumID: ForumID) -> Topic? {
        guard let tid = int64(dictionary["tid"]),
              let rawSubject = string(dictionary["subject"]) else { return nil }
        let subject = normalizedTopicListText(rawSubject)
        guard !subject.isEmpty else { return nil }
        let sourceForum = topicSourceForum(in: dictionary)
        let mirroredForumID = mirroredForumID(in: dictionary)
        let subjectColor = topicSubjectColor(in: dictionary)
        return Topic(
            id: TopicID(rawValue: tid),
            forumID: ForumID(rawValue: int64(dictionary["fid"]) ?? fallbackForumID.rawValue),
            subject: subject,
            author: normalizedUsername(string(dictionary["author"])) ?? "",
            authorUID: postAuthorID(in: dictionary),
            replyCount: int(dictionary["replies"]) ?? int(dictionary["replyCount"]) ?? 0,
            publishedAt: date(dictionary["postdate"]),
            lastReplyAt: date(dictionary["lastpost"]),
            isPinned: mirroredForumID == nil &&
                ((int(dictionary["type"]) ?? 0) > 0 || bool(dictionary["pinned"])),
            isLocked: bool(dictionary["locked"]) || (int(dictionary["locked"]) ?? 0) > 0,
            sourceForumID: sourceForum?.id,
            sourceParentForumID: sourceForum?.parentID,
            sourceForumName: sourceForum?.name,
            mirroredForumID: mirroredForumID,
            isFavorite: bool(dictionary["favor"])
                || bool(dictionary["favorite"])
                || (int(dictionary["favor"]) ?? 0) > 0
                || (int(dictionary["favorite"]) ?? 0) > 0,
            subjectColor: subjectColor
        )
    }

    private func topicSubjectColor(in dictionary: [String: Any]) -> TopicSubjectColor? {
        let encodedValues = [
            string(dictionary["topic_misc"]),
            string(dictionary["titlefont"])
        ]
        for encodedValue in encodedValues.compactMap({ $0 }) {
            guard let bits = topicSubjectFontModifierBits(encodedValue) else { continue }
            let colors: [(TopicSubjectColor, UInt32)] = [
                (.red, 0x1),
                (.blue, 0x2),
                (.green, 0x4),
                (.orange, 0x8),
                (.silver, 0x10)
            ]
            if let color = colors.last(where: { bits & $0.1 != 0 })?.0 {
                return color
            }
        }
        return nil
    }

    private func topicSubjectFontModifierBits(_ encodedValue: String) -> UInt32? {
        var normalized = encodedValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !normalized.isEmpty else { return nil }
        let paddingCount = (4 - normalized.count % 4) % 4
        normalized.append(String(repeating: "=", count: paddingCount))
        guard let data = Data(base64Encoded: normalized) else { return nil }

        let bytes = [UInt8](data)
        var cursor = 0
        while cursor < bytes.count {
            let dataType = bytes[cursor]
            cursor += 1
            guard cursor + 4 <= bytes.count else { return nil }
            let value = UInt32(bytes[cursor]) << 24
                | UInt32(bytes[cursor + 1]) << 16
                | UInt32(bytes[cursor + 2]) << 8
                | UInt32(bytes[cursor + 3])
            cursor += 4
            switch dataType {
            case 1:
                return value
            case 2:
                continue
            default:
                return nil
            }
        }
        return nil
    }

    private func mirroredForumID(in dictionary: [String: Any]) -> ForumID? {
        guard let values = dictionary["topic_misc_var"] as? [String: Any],
              let rawForumID = int64(values["3"]),
              rawForumID > 0 else {
            return nil
        }
        let type = int64(dictionary["type"]) ?? 0
        let parentName = (dictionary["parent"] as? [String: Any])
            .flatMap { string($0["2"]) }
        guard type & 2_097_152 != 0 || parentName == "版面镜像" else {
            return nil
        }
        return ForumID(rawValue: rawForumID)
    }

    private func subforums(from forumMetadata: [String: Any]) -> [Forum] {
        guard let values = forumMetadata["sub_forums"] as? [String: Any] else {
            return []
        }
        return values.compactMap { key, rawValue -> Forum? in
            if let dictionary = rawValue as? [String: Any] {
                return forum(from: dictionary)
            }
            guard let fields = rawValue as? [Any],
                  let rawID = fields.first.flatMap(int64),
                  fields.count > 1,
                  let rawName = string(fields[1]) else {
                return nil
            }
            let name = plainText(rawName)
            guard !name.isEmpty else { return nil }
            let id: ForumID
            if key.lowercased().hasPrefix("t") {
                guard rawID >= 0 else { return nil }
                id = ForumID(stid: rawID)
            } else {
                id = ForumID(rawValue: rawID)
            }
            let subtitle = fields.count > 2 ? string(fields[2]).map(plainText) : nil
            let pinnedTopicID = fields.count > 3
                ? int64(fields[3]).flatMap { $0 > 0 ? TopicID(rawValue: $0) : nil }
                : nil
            let attributes = fields.count > 4 ? int(fields[4]) : nil
            return Forum(
                id: id,
                name: name,
                subtitle: subtitle,
                pinnedTopicID: pinnedTopicID,
                isSelectedInParent: attributes.map(isSelectedSubforumAttributes)
            )
        }
    }

    private func selectedSubforumState(from dictionary: [String: Any]) -> Bool? {
        for key in ["selected", "is_selected", "checked"] where dictionary[key] != nil {
            return bool(dictionary[key])
        }
        for key in ["attributes", "attribute", "attr"] {
            if let attributes = int(dictionary[key]) {
                return isSelectedSubforumAttributes(attributes)
            }
        }
        return nil
    }

    private func isSelectedSubforumAttributes(_ attributes: Int) -> Bool {
        // NGA 没有单独提供布尔字段，网页版也根据这组版面属性值决定默认勾选状态。
        [7, 542, 558, 2_590, 2_606, 4_654].contains(attributes)
    }

    private func topicSourceForum(
        in dictionary: [String: Any]
    ) -> (id: ForumID, parentID: ForumID?, name: String?)? {
        guard let parent = dictionary["parent"] as? [String: Any] else {
            return nil
        }
        let parentID = int64(parent["0"]).map {
            ForumID(rawValue: $0)
        }
        let id: ForumID
        if let stid = int64(parent["1"]), stid > 0 {
            id = ForumID(stid: stid)
        } else if let parentID {
            id = parentID
        } else {
            return nil
        }
        return (id, parentID, string(parent["2"]).map(normalizedTopicListText))
    }

    private struct PostUser {
        var name: String
        var avatarURL: URL?
        var authorInfo: PostAuthorInfo?
    }

    private struct ForumLevelRule {
        var threshold: Int
        var title: String
    }

    private struct MedalDefinition {
        var filename: String
        var name: String
        var detail: String?
    }

    private struct HTMLPostMetadata {
        var pid: Int64?
        var authorUID: Int64?
        var postedAt: Date?
        var device: PostDevice
        var upvoteCount: Int
        var downvoteCount: Int
    }

    private func htmlFloor(in row: Element) throws -> Int? {
        if let name = try row.select("a[name^='l']").first?.attr("name"),
           let floor = Int(name.dropFirst()) {
            return floor
        }
        return digits(in: row.id()).flatMap(Int.init)
    }

    private func htmlPostContent(in row: Element, floor: Int) throws -> Element? {
        // NGA 会用 postcontentandsubject 包住标题和正文；必须先按楼层精确
        // 选择正文，否则组合选择器会按文档顺序先命中外层包装节点。
        if let exactContent = try row.select(
            "#postcontent\(floor), #post_content\(floor)"
        ).first {
            return exactContent
        }
        return try row.select(
            "[id^='postcontent'], [id^='post_content'], .postcontent, .postContent"
        ).first { !isHTMLPostContentAndSubjectWrapper($0) }
    }

    private func isHTMLPostContentAndSubjectWrapper(_ element: Element) -> Bool {
        element.id()
            .lowercased()
            .replacing("_", with: "")
            .hasPrefix("postcontentandsubject")
    }

    private func htmlUserMap(in source: String) -> [Int64: PostUser] {
        guard let arguments = javaScriptCallArguments(
            in: source,
            marker: "commonui.userInfo.setAll("
        ).first,
              let rawValue = splitJavaScriptArguments(arguments).first else {
            return [:]
        }
        let candidates = [
            rawValue,
            rawValue
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
        ]
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                  ) else {
                continue
            }
            let users = userMap(in: value)
            if !users.isEmpty { return users }
        }
        return [:]
    }

    private func htmlPostMetadata(in source: String) -> [Int: HTMLPostMetadata] {
        var result: [Int: HTMLPostMetadata] = [:]
        for call in javaScriptCallArguments(
            in: source,
            marker: "commonui.postArg.proc("
        ) {
            let arguments = splitJavaScriptArguments(call)
            guard arguments.count >= 15,
                  let floor = Int(normalizedJavaScriptLiteral(arguments[0])) else {
                continue
            }
            let timestamp = Int64(normalizedJavaScriptLiteral(arguments[14]))
            let scoreValues = arguments.count > 15
                ? normalizedJavaScriptLiteral(arguments[15])
                    .split(separator: ",")
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                : []
            let score = scoreValues.count > 1 ? scoreValues[1] : 0
            let rawDevice = arguments.count > 19
                ? normalizedJavaScriptLiteral(arguments[19])
                : nil
            result[floor] = HTMLPostMetadata(
                pid: Int64(normalizedJavaScriptLiteral(arguments[10])),
                authorUID: Int64(normalizedJavaScriptLiteral(arguments[13])),
                postedAt: timestamp.flatMap {
                    $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
                },
                device: postDevice(from: rawDevice),
                upvoteCount: max(0, score),
                downvoteCount: max(0, -score)
            )
        }
        return result
    }

    private func htmlTopicPoll(in source: String, topicID: TopicID) -> TopicPoll? {
        for call in javaScriptCallArguments(in: source, marker: "commonui.vote(") {
            let arguments = splitJavaScriptArguments(call)
            guard arguments.count >= 3,
                  Int64(normalizedJavaScriptLiteral(arguments[1])) == topicID.rawValue else {
                continue
            }
            let rawValue = normalizedJavaScriptLiteral(arguments[2])
            if let poll = topicPoll(from: rawValue, topicID: topicID) {
                return poll
            }
        }
        return nil
    }

    private func htmlRatings(
        in source: String,
        topicID: TopicID
    ) -> (topicRating: TopicRating?, postScores: [Int: [String: Int]]) {
        var rating: TopicRating?
        var postScores: [Int: [String: Int]] = [:]

        for call in javaScriptCallArguments(in: source, marker: "commonui.vote(") {
            let arguments = splitJavaScriptArguments(call)
            guard arguments.count >= 3,
                  Int64(normalizedJavaScriptLiteral(arguments[1])) == topicID.rawValue else {
                continue
            }
            let rawValue = normalizedJavaScriptLiteral(arguments[2])
            if rating == nil,
               let parsedRating = topicRating(from: rawValue, topicID: topicID) {
                rating = parsedRating
            }
            if let scores = postRatingScores(from: rawValue),
               let floor = digits(in: arguments[0]).flatMap(Int.init) {
                postScores[floor] = scores
            }
        }
        return (rating, postScores)
    }

    private func javaScriptCallArguments(in source: String, marker: String) -> [String] {
        var result: [String] = []
        var searchStart = source.startIndex

        while searchStart < source.endIndex,
              let markerRange = source.range(
                of: marker,
                range: searchStart..<source.endIndex
              ) {
            let contentStart = markerRange.upperBound
            var index = contentStart
            var depth = 1
            var quote: Character?
            var isEscaped = false

            while index < source.endIndex {
                let character = source[index]
                if isEscaped {
                    isEscaped = false
                } else if character == "\\", quote != nil {
                    isEscaped = true
                } else if character == "'" || character == "\"" {
                    if quote == character {
                        quote = nil
                    } else if quote == nil {
                        quote = character
                    }
                } else if quote == nil {
                    if character == "(" {
                        depth += 1
                    } else if character == ")" {
                        depth -= 1
                        if depth == 0 {
                            result.append(String(source[contentStart..<index]))
                            index = source.index(after: index)
                            break
                        }
                    }
                }
                index = source.index(after: index)
            }
            guard index > contentStart else { break }
            searchStart = index
        }
        return result
    }

    private func splitJavaScriptArguments(_ source: String) -> [String] {
        var result: [String] = []
        var current = ""
        var roundDepth = 0
        var squareDepth = 0
        var curlyDepth = 0
        var quote: Character?
        var isEscaped = false

        for character in source {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\", quote != nil {
                current.append(character)
                isEscaped = true
                continue
            }
            if character == "'" || character == "\"" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                current.append(character)
                continue
            }
            if quote == nil {
                switch character {
                case "(": roundDepth += 1
                case ")": roundDepth = max(0, roundDepth - 1)
                case "[": squareDepth += 1
                case "]": squareDepth = max(0, squareDepth - 1)
                case "{": curlyDepth += 1
                case "}": curlyDepth = max(0, curlyDepth - 1)
                case "," where roundDepth == 0 && squareDepth == 0 && curlyDepth == 0:
                    result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                    continue
                default: break
                }
            }
            current.append(character)
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private func normalizedJavaScriptLiteral(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.caseInsensitiveCompare("null") == .orderedSame {
            return ""
        }
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "'" && last == "'") || (first == "\"" && last == "\"") else {
            return value
        }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func post(
        from dictionary: [String: Any],
        topicID: TopicID,
        users: [Int64: PostUser],
        topicAuthor: String = ""
    ) -> Post? {
        guard let content = postContent(in: dictionary) else { return nil }
        let rawPID = int64(dictionary["pid"]) ?? int64(dictionary["postid"])
        let rawFloor = int(dictionary["lou"]) ?? int(dictionary["floor"]) ?? 0
        // NGA 的结构化响应以 pid=0 表示话题首帖。少数页面变体会把 lou
        // 写成 1；首帖身份应以 pid 为准，避免在界面上误标为 #1。
        let floor = rawPID == 0 ? 0 : rawFloor
        let pid = rawPID
            ?? stableID(for: "\(topicID.rawValue):\(floor):\(content)")
        let authorUID = postAuthorID(in: dictionary)
        let user = authorUID.flatMap { users[$0] }
        let inlineAuthor = [
            "author", "username", "author_name", "authorName"
        ].lazy.compactMap {
            normalizedUsername(string(dictionary[$0]))
        }.first
        let author: String
        if let inlineAuthor, !inlineAuthor.isEmpty {
            author = inlineAuthor
        } else if let user {
            author = user.name
        } else if floor == 0, let topicAuthor = normalizedUsername(topicAuthor) {
            author = topicAuthor
        } else if let authorUID {
            author = "用户 \(authorUID)"
        } else {
            author = "未知用户"
        }
        let inlineAvatar = remoteResourceURL(string(dictionary["avatar"]), kind: .avatar)
        let postTopicID = TopicID(rawValue: int64(dictionary["tid"]) ?? topicID.rawValue)
        let rawVote = string(dictionary["vote"])
        let rawDevice = ["from_client", "fromClient", "client", "device"]
            .lazy
            .compactMap { string(dictionary[$0]) }
            .first
        return Post(
            id: PostID(rawValue: pid),
            topicID: postTopicID,
            floor: floor,
            author: author,
            authorUID: authorUID,
            avatarURL: inlineAvatar ?? user?.avatarURL,
            authorInfo: user?.authorInfo,
            postedAt: date(dictionary["postdatetimestamp"]) ?? date(dictionary["postdate"]),
            device: postDevice(from: rawDevice),
            html: content,
            quotedPostID: (
                int64(dictionary["reply_to"]) ?? referencedPostID(in: content)
            ).map(PostID.init(rawValue:)),
            upvoteCount: max(
                0,
                int(dictionary["vote_up"])
                    ?? int(dictionary["upvote"])
                    ?? int(dictionary["up"])
                    ?? int(dictionary["score"])
                    ?? 0
            ),
            downvoteCount: max(
                0,
                int(dictionary["vote_down"])
                    ?? int(dictionary["downvote"])
                    ?? int(dictionary["down"])
                    ?? 0
            ),
            userVote: int(dictionary["user_vote"]).flatMap(voteDirection),
            poll: rawVote.flatMap {
                topicPoll(from: $0, topicID: postTopicID)
            },
            ratingScores: rawVote.flatMap(postRatingScores) ?? [:]
        )
    }

    private func postDevice(from rawValue: String?) -> PostDevice {
        let value = rawValue?.lowercased() ?? ""
        if value.contains("android") {
            return .android
        }
        if value.contains("ios") || value.contains("iphone") || value.contains("ipad") {
            return .apple
        }
        return .desktop
    }

    private func topicVoteValue(in dictionary: [String: Any]) -> String? {
        if let value = string(dictionary["vote"]) {
            return value
        }
        for key in ["post_misc_var", "topic_misc_var"] {
            if let nested = dictionary[key] as? [String: Any],
               let value = string(nested["vote"]) {
                return value
            }
        }
        return nil
    }

    private func votePairs(from rawValue: String) -> [(key: String, value: String)] {
        let components = rawValue.components(separatedBy: "~")
        guard components.count >= 2 else { return [] }

        var pairs: [(key: String, value: String)] = []
        for index in stride(from: 0, to: components.count - 1, by: 2) {
            pairs.append((components[index], components[index + 1]))
        }
        return pairs
    }

    private func voteValues(
        from pairs: [(key: String, value: String)]
    ) -> [String: String] {
        Dictionary(
            pairs.map { ($0.key, $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private func topicPoll(from rawValue: String, topicID: TopicID) -> TopicPoll? {
        let orderedPairs = votePairs(from: rawValue)
        guard !orderedPairs.isEmpty else { return nil }
        let values = voteValues(from: orderedPairs)

        // The same field also carries betting and score widgets. Only type 0 is
        // a regular forum poll that can be represented by this model.
        guard Int(values["type"] ?? "0") == 0 else { return nil }

        var groups: [TopicPoll.Group] = []
        var currentGroup = TopicPoll.Group(id: 0, title: nil, options: [])
        var nextGroupID = 0
        var participantCount = 0

        for pair in orderedPairs where Int64(pair.key) != nil {
            let title = plainText(pair.value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if topicID.rawValue > 38_056_407, title.hasPrefix("===") {
                if !currentGroup.options.isEmpty {
                    groups.append(currentGroup)
                }
                nextGroupID += 1
                let groupTitle = String(title.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentGroup = TopicPoll.Group(
                    id: nextGroupID,
                    title: groupTitle.isEmpty ? nil : groupTitle,
                    options: []
                )
                continue
            }

            let counts = values["_\(pair.key)"]?
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
                ?? []
            let voteCount = max(0, counts.first ?? 0)
            if counts.count > 2 {
                participantCount = max(participantCount, counts[2])
            }
            currentGroup.options.append(TopicPoll.Option(
                id: pair.key,
                title: title,
                voteCount: voteCount
            ))
        }
        if !currentGroup.options.isEmpty {
            groups.append(currentGroup)
        }
        guard !groups.isEmpty else { return nil }

        let options = Int(values["opt"] ?? "0") ?? 0
        let endTimestamp = Int64(values["end"] ?? "").flatMap { timestamp in
            timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
        }
        return TopicPoll(
            id: topicID,
            groups: groups,
            maximumSelectionsPerGroup: max(1, Int(values["max_select"] ?? "1") ?? 1),
            endsAt: endTimestamp,
            hidesResultsUntilVoting: options & 1 != 0,
            hidesResultsUntilEnd: options & 2 != 0,
            participantCount: max(0, participantCount)
        )
    }

    private func topicRating(from rawValue: String, topicID: TopicID) -> TopicRating? {
        let orderedPairs = votePairs(from: rawValue)
        guard !orderedPairs.isEmpty else { return nil }
        let values = voteValues(from: orderedPairs)
        guard Int(values["type"] ?? "") == 2,
              let minimumScore = Int(values["min"] ?? ""),
              let maximumScore = Int(values["max"] ?? ""),
              minimumScore <= maximumScore,
              maximumScore > 0 else {
            return nil
        }
        let (scoreSpan, scoreSpanOverflow) = maximumScore
            .subtractingReportingOverflow(minimumScore)
        guard !scoreSpanOverflow, scoreSpan <= 100 else { return nil }

        var dimensions: [TopicRatingDimension] = []
        var participantCount = 0
        for pair in orderedPairs
        where Int64(pair.key).map({ $0 > 0 }) == true {
            let title = plainText(pair.value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let counts = values["_\(pair.key)"]?
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
                ?? []
            let ratingCount = max(0, counts.first ?? 0)
            let totalScore = max(0, counts.count > 1 ? counts[1] : 0)
            if counts.count > 2 {
                participantCount = max(participantCount, counts[2])
            }
            dimensions.append(TopicRatingDimension(
                id: pair.key,
                title: title,
                ratingCount: ratingCount,
                totalScore: totalScore
            ))
        }
        guard !dimensions.isEmpty else { return nil }

        let endTimestamp = Int64(values["end"] ?? "").flatMap { timestamp in
            timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
        }
        return TopicRating(
            id: topicID,
            dimensions: dimensions,
            minimumScore: minimumScore,
            maximumScore: maximumScore,
            endsAt: endTimestamp,
            participantCount: max(0, participantCount)
        )
    }

    private func postRatingScores(from rawValue: String) -> [String: Int]? {
        let pairs = votePairs(from: rawValue)
        guard !pairs.isEmpty else { return nil }
        let values = voteValues(from: pairs)
        guard Int(values["type"] ?? "") == 3 else { return nil }

        let scores: [String: Int] = Dictionary(
            pairs.compactMap { pair -> (String, Int)? in
                guard Int64(pair.key).map({ $0 > 0 }) == true,
                      let score = Int(pair.value) else {
                    return nil
                }
                return (pair.key, score)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        return scores.isEmpty ? nil : scores
    }

    private func referencedPostID(in content: String) -> Int64? {
        guard let expression = CachedRegularExpressions.shared.expression(
            pattern: #"\[pid=(\d+)(?:,[^\]]*)?\]"#,
            options: .caseInsensitive
        ) else { return nil }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = expression.firstMatch(in: content, range: range),
              let capture = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return Int64(content[capture])
    }

    private func voteDirection(_ rawValue: Int) -> PostVoteDirection? {
        switch rawValue {
        case 1: .up
        case 0: .down
        default: nil
        }
    }

    private func threadPayload(in root: Any) -> [String: Any]? {
        guard let root = root as? [String: Any] else { return nil }
        if root["__R"] != nil { return root }
        if let data = root["data"] as? [String: Any], data["__R"] != nil {
            return data
        }
        return dictionaries(in: root).first { $0["__R"] != nil }
    }

    private func topicDictionary(
        in payload: [String: Any],
        topicID: TopicID
    ) -> [String: Any]? {
        guard let rawTopic = payload["__T"] else { return nil }
        return orderedDictionaries(in: rawTopic).first {
            int64($0["tid"]) == topicID.rawValue
        }
    }

    private func postDictionaries(
        in root: Any,
        payload: [String: Any]? = nil
    ) -> [[String: Any]] {
        if let replies = payload?["__R"] {
            let result = orderedDictionaries(in: replies).filter {
                postContent(in: $0) != nil
            }
            if !result.isEmpty { return result }
        }
        return dictionaries(in: root).filter {
            postContent(in: $0) != nil &&
                (
                    int64($0["pid"]) != nil ||
                    int64($0["postid"]) != nil ||
                    int($0["lou"]) != nil ||
                    int($0["floor"]) != nil
                )
        }
    }

    private func hotReplyDictionaries(in payload: [String: Any]?) -> [[String: Any]] {
        guard let replies = payload?["__R"] else { return [] }
        let topicPost = orderedDictionaries(in: replies).first {
            int64($0["pid"]) == 0 || int($0["lou"]) == 0 || int($0["floor"]) == 0
        }
        guard let hotReplies = topicPost?["hotreply"] else { return [] }
        return orderedDictionaries(in: hotReplies).filter {
            postContent(in: $0) != nil
        }
    }

    private func orderedDictionaries(in value: Any) -> [[String: Any]] {
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        guard let dictionary = value as? [String: Any] else { return [] }
        if postContent(in: dictionary) != nil || int64(dictionary["tid"]) != nil {
            return [dictionary]
        }
        return dictionary
            .compactMap { key, value -> (numericKey: Int64?, key: String, value: [String: Any])? in
                guard let value = value as? [String: Any] else { return nil }
                return (Int64(key), key, value)
            }
            .sorted { lhs, rhs in
                switch (lhs.numericKey, rhs.numericKey) {
                case let (left?, right?): left == right ? lhs.key < rhs.key : left < right
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): lhs.key < rhs.key
                }
            }
            .map(\.value)
    }

    private func postAuthorID(in dictionary: [String: Any]) -> Int64? {
        int64(dictionary["authorid"])
            ?? int64(dictionary["author_id"])
            ?? int64(dictionary["authorId"])
            ?? int64(dictionary["uid"])
    }

    private func postOrder(_ lhs: Post, _ rhs: Post) -> Bool {
        if lhs.floor != rhs.floor { return lhs.floor < rhs.floor }
        if lhs.postedAt != rhs.postedAt {
            return (lhs.postedAt ?? .distantPast) < (rhs.postedAt ?? .distantPast)
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private func postContent(in dictionary: [String: Any]) -> String? {
        ["content", "postcontent", "post_content", "body"]
            .lazy
            .compactMap { string(dictionary[$0]) }
            .first
    }

    private func postUsers(in root: Any) -> [Int64: PostUser] {
        guard let container = dictionaries(in: root).first(where: { $0["__U"] != nil }),
              let value = container["__U"] else {
            return [:]
        }
        let customLevelSource = (container["__F"] as? [String: Any])
            .flatMap { string($0["custom_level"]) }
        return userMap(in: value, customLevelSource: customLevelSource)
    }

    private func userMap(
        in value: Any,
        customLevelSource: String? = nil
    ) -> [Int64: PostUser] {
        var result: [Int64: PostUser] = [:]
        var nextAnonymousUID: Int64 = -1
        let container = value as? [String: Any]
        let groupNames = userGroupNames(in: container?["__GROUPS"])
        let medalDefinitions = medalDefinitions(in: container?["__MEDALS"])
        let reputationScores = userReputationScores(in: container?["__REPUTATIONS"])
        let levelRules = forumLevelRules(from: customLevelSource)

        func visit(_ value: Any, keyHint: Int64? = nil) {
            if let array = value as? [Any] {
                array.forEach { visit($0) }
                return
            }
            guard let dictionary = value as? [String: Any] else { return }

            let uid = int64(dictionary["uid"])
                ?? int64(dictionary["id"])
                ?? int64(dictionary["0"])
                ?? keyHint
            let rawName = string(dictionary["username"])
                ?? string(dictionary["name"])
                ?? string(dictionary["author"])
                ?? string(dictionary["1"])
            if let name = normalizedUsername(rawName) {
                let isAnonymous = rawName.map(plainText)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix("#anony_") == true
                let resolvedUID: Int64?
                if isAnonymous {
                    // Anonymous boards expose post author IDs as -1, -2, ... while
                    // user records may all report uid=0. NGA defines their mapping
                    // by __U order (or by a negative object key when one is present).
                    resolvedUID = keyHint.flatMap { $0 < 0 ? $0 : nil }
                        ?? uid.flatMap { $0 < 0 ? $0 : nil }
                        ?? nextAnonymousUID
                    nextAnonymousUID -= 1
                } else {
                    resolvedUID = uid ?? keyHint
                }
                if let resolvedUID {
                    let reputation = reputationScores[resolvedUID]
                    let matchedLevelIndex = reputation.flatMap { score in
                        levelRules.lastIndex { $0.threshold <= score }
                    }
                    let levelOffset = (levelRules.first?.threshold ?? 0) < 0 ? 1 : 0
                    let medals = userMedals(
                        from: dictionary["medal"],
                        definitions: medalDefinitions
                    )
                    let authorInfo = PostAuthorInfo(
                        levelTitle: matchedLevelIndex.map { levelRules[$0].title },
                        reputation: reputation,
                        reputationLevel: matchedLevelIndex.map { max(0, $0 - levelOffset) },
                        userGroup: (int(dictionary["groupid"]) ?? int(dictionary["memberid"]))
                            .flatMap { groupNames[$0] }
                            ?? nonEmptyString(dictionary["group"]),
                        registeredAt: date(dictionary["regdate"]),
                        prestige: int(dictionary["rvrc"]).map { Double($0) / 10 },
                        location: nonEmptyString(dictionary["ipLoc"]),
                        medals: medals,
                        honor: normalizedUserHonor(string(dictionary["honor"]))
                    )
                    result[resolvedUID] = PostUser(
                        name: name,
                        avatarURL: remoteResourceURL(string(dictionary["avatar"]), kind: .avatar),
                        authorInfo: hasVisibleAuthorInfo(authorInfo) ? authorInfo : nil
                    )
                }
                return
            }

            let children = dictionary.map { (key: $0.key, value: $0.value) }
                .sorted { lhs, rhs in
                    switch (Int64(lhs.key), Int64(rhs.key)) {
                    case let (left?, right?):
                        return left == right ? lhs.key < rhs.key : left < right
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        return lhs.key < rhs.key
                    }
                }
            for child in children {
                visit(child.value, keyHint: Int64(child.key))
            }
        }

        visit(value)
        return result
    }

    private func userGroupNames(in value: Any?) -> [Int: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [:]) { result, entry in
            guard let groupID = Int(entry.key) else { return }
            let name: String?
            if let values = entry.value as? [Any] {
                name = values.first.flatMap(string)
            } else if let group = entry.value as? [String: Any] {
                name = string(group["name"]) ?? string(group["title"]) ?? string(group["0"])
            } else {
                name = string(entry.value)
            }
            if let name = name.map(plainText)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                result[groupID] = name
            }
        }
    }

    private func medalDefinitions(in value: Any?) -> [Int: MedalDefinition] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [:]) { result, entry in
            guard let medalID = Int(entry.key) else { return }
            let filename: String?
            let name: String?
            let detail: String?
            if let values = entry.value as? [Any] {
                filename = values.indices.contains(0) ? string(values[0]) : nil
                name = values.indices.contains(1) ? string(values[1]) : nil
                detail = values.indices.contains(2) ? string(values[2]) : nil
            } else if let medal = entry.value as? [String: Any] {
                filename = string(medal["image"]) ?? string(medal["filename"]) ?? string(medal["0"])
                name = string(medal["name"]) ?? string(medal["title"]) ?? string(medal["1"])
                detail = string(medal["description"]) ?? string(medal["detail"]) ?? string(medal["2"])
            } else {
                return
            }
            guard let filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !filename.isEmpty else {
                return
            }
            let normalizedName = name.map(plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let normalizedDetail = detail.map(plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result[medalID] = MedalDefinition(
                filename: filename,
                name: normalizedName.isEmpty ? "徽章 \(medalID)" : normalizedName,
                detail: normalizedDetail.isEmpty ? nil : normalizedDetail
            )
        }
    }

    private func userReputationScores(in value: Any?) -> [Int64: Int] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var result: [Int64: Int] = [:]
        let reputations = dictionary.sorted {
            (Int($0.key) ?? .max) < (Int($1.key) ?? .max)
        }
        for reputation in reputations {
            guard let scores = reputation.value as? [String: Any] else { continue }
            for (rawUID, rawScore) in scores {
                guard let uid = Int64(rawUID), uid > 0, result[uid] == nil,
                      let score = int(rawScore) else {
                    continue
                }
                result[uid] = score
            }
        }
        return result
    }

    private func forumLevelRules(from source: String?) -> [ForumLevelRule] {
        guard let source,
              let expression = CachedRegularExpressions.shared.expression(
                pattern: #"\{\s*r\s*:\s*(-?\d+)\s*,\s*n\s*:\s*[\"']([^\"']+)[\"']\s*\}"#
              ) else {
            return []
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges == 3,
                  let thresholdRange = Range(match.range(at: 1), in: source),
                  let titleRange = Range(match.range(at: 2), in: source),
                  let threshold = Int(source[thresholdRange]) else {
                return nil
            }
            return ForumLevelRule(
                threshold: threshold,
                title: plainText(String(source[titleRange]))
            )
        }
        .sorted { $0.threshold < $1.threshold }
    }

    private func userMedals(
        from value: Any?,
        definitions: [Int: MedalDefinition]
    ) -> [UserMedal] {
        guard let rawValue = string(value) else { return [] }
        let baseURL = URL(string: "https://img4.nga.cn/ngabbs/medal/")
        return rawValue.split(separator: ",").compactMap { rawID in
            guard let id = Int(rawID.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let definition = definitions[id] else {
                return nil
            }
            return UserMedal(
                id: id,
                name: definition.name,
                detail: definition.detail,
                imageURL: URL(string: definition.filename, relativeTo: baseURL)?.absoluteURL
            )
        }
    }

    private func normalizedUserHonor(_ value: String?) -> String? {
        guard let value else { return nil }
        let honor = plainText(value)
            .replacingOccurrences(
                of: #"^\s*\d{9,}\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "$notitle$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return honor.isEmpty ? nil : honor
    }

    private func hasVisibleAuthorInfo(_ info: PostAuthorInfo) -> Bool {
        info.levelTitle != nil ||
            info.reputation != nil ||
            info.userGroup != nil ||
            info.registeredAt != nil ||
            info.prestige != nil ||
            info.location != nil ||
            !info.medals.isEmpty ||
            info.honor != nil
    }

    private func message(from dictionary: [String: Any], folder: MessageFolder) -> ForumMessage? {
        guard let mid = int64(dictionary["mid"]) ?? int64(dictionary["id"]),
              let rawSubject = string(dictionary["subject"]) ?? string(dictionary["title"]) else {
            return nil
        }
        let subject = plainText(rawSubject)
        guard !subject.isEmpty else { return nil }
        let rawKind = (string(dictionary["type"]) ?? subject).lowercased()
        let sender = normalizedUsername(string(dictionary["from_username"]))
            ?? normalizedUsername(string(dictionary["to_username"]))
            ?? names(in: string(dictionary["all_user"])).first
            ?? ""
        let count = int(dictionary["posts"]) ?? int(dictionary["count"]) ?? 0
        let rawPreview = string(dictionary["content"])
            ?? string(dictionary["preview"])
            ?? (count > 0 ? "共 \(count) 条消息" : "")
        let preview = plainText(rawPreview)
        return ForumMessage(
            id: MessageID(rawValue: mid),
            kind: kind(from: rawKind, folder: folder),
            sender: sender,
            subject: subject,
            preview: preview,
            html: string(dictionary["content"]),
            sentAt: date(dictionary["last_modify"]) ?? date(dictionary["time"]) ?? date(dictionary["postdate"]),
            isUnread: bool(dictionary["unread"])
                || (int(dictionary["read"]) ?? 1) == 0
                || (int(dictionary["bit"]) ?? 0) == 1,
            topicID: int64(dictionary["tid"]).map(TopicID.init(rawValue:)),
            replyURL: url(dictionary["url"])
        )
    }

    private func notificationMessage(from dictionary: [String: Any]) -> ForumMessage? {
        guard let rawType = int(dictionary["0"]) else { return nil }
        let timestamp = int64(dictionary["9"])
        let sender = normalizedUsername(string(dictionary["2"])) ?? ""
        let subject = string(dictionary["5"]).map(plainText) ?? "论坛提醒"
        let topicID = int64(dictionary["6"]).map(TopicID.init(rawValue:))
        let postID = int64(dictionary["8"])
        let kind: ForumMessageKind
        switch rawType {
        case 1, 2: kind = .reply
        case 3, 4: kind = .comment
        case 7, 8: kind = .mention
        case 10, 11: kind = .privateMessage
        default: kind = .unknown
        }
        let identity = [
            timestamp.map(String.init) ?? "",
            String(rawType),
            sender,
            subject,
            string(dictionary["6"]) ?? "",
            string(dictionary["7"]) ?? "",
            string(dictionary["8"]) ?? ""
        ].joined(separator: ":")
        var components = URLComponents(
            url: NGAEndpoint.baseURL.appending(path: "read.php"),
            resolvingAgainstBaseURL: false
        )
        if let topicID {
            components?.queryItems = [
                .init(name: "tid", value: topicID.description),
                .init(name: "pid", value: postID.map(String.init))
            ].filter { $0.value?.isEmpty == false }
        }
        return ForumMessage(
            id: MessageID(rawValue: stableID(for: identity)),
            kind: kind,
            sender: sender,
            subject: kind == .privateMessage
                ? "短消息"
                : (subject.isEmpty ? kind.notificationTitle : subject),
            preview: notificationPreview(rawType: rawType, sender: sender),
            sentAt: timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            isUnread: bool(dictionary["unread"])
                || (int(dictionary["read"]) == 0),
            topicID: topicID,
            replyURL: components?.url
        )
    }

    private func notificationPreview(rawType: Int, sender: String) -> String {
        let actor = sender.isEmpty ? "有用户" : sender
        switch rawType {
        case 1: return "\(actor) 回复了你的话题"
        case 2: return "\(actor) 回复了你的回复"
        case 3: return "\(actor) 评价了你的话题"
        case 4: return "\(actor) 评价了你的回复"
        case 7: return "\(actor) 在话题中提到了你"
        case 8: return "\(actor) 在回复中提到了你"
        case 10, 11: return sender.isEmpty ? "收到一条短消息" : "\(sender) 发来一条短消息"
        default: return "收到一条论坛通知"
        }
    }

    private func names(in allUsers: String?) -> [String] {
        guard let allUsers else { return [] }
        let values = allUsers.components(separatedBy: "\t")
        return stride(from: 1, to: values.count, by: 2).compactMap { index in
            normalizedUsername(values[index])
        }
    }

    private func notificationUnreadCount(in payload: Any) -> Int? {
        dictionaries(in: payload)
            .compactMap { int($0["unread"]) }
            .first
    }

    private func notificationPayload(in value: Any) -> Any {
        // NGA 会把提醒对象作为 JavaScript 字符串放进 data[0]，且数字键没有引号；
        // 先解开这一层，再沿用普通 JSON 提醒解析。
        for source in strings(in: value) {
            guard let openingBrace = source.firstIndex(of: "{"),
                  let closingBrace = source.lastIndex(of: "}"),
                  openingBrace < closingBrace else {
                continue
            }
            let object = String(source[openingBrace...closingBrace])
            let normalized = replacingMatches(
                in: object,
                pattern: #"([,{]\s*)(\d+)\s*:"#
            ) { captures in
                "\(captures[0])\"\(captures[1])\":"
            }
            if let payload = jsonRoot(normalized) {
                return payload
            }
        }
        return value
    }

    private func normalizedUsername(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = plainText(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return anonymousDisplayName(from: value) ?? value
    }

    private func anonymousDisplayName(from value: String) -> String? {
        let prefix = "#anony_"
        guard value.hasPrefix(prefix) else { return nil }
        let code = String(value.dropFirst(prefix.count))
        guard code.count == 32, code.allSatisfy(\.isHexDigit) else { return nil }

        let heavenlyStemsAndBranches = Array("甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥")
        let surnames = Array(
            "王李张刘陈杨黄吴赵周徐孙马朱胡林郭何高罗郑梁谢宋唐许邓冯韩曹曾彭萧蔡潘田董袁于余叶蒋杜苏魏程吕丁沈任姚卢傅钟姜崔谭廖范汪陆金石戴贾韦夏邱方侯邹熊孟秦白江阎薛尹段雷黎史龙陶贺顾毛郝龚邵万钱严赖覃洪武莫孔汤向常温康施文牛樊葛邢安齐易乔伍庞颜倪庄聂章鲁岳翟殷詹申欧耿关兰焦俞左柳甘祝包宁尚符舒阮柯纪梅童凌毕单季裴霍涂成苗谷盛曲翁冉骆蓝路游辛靳管柴蒙鲍华喻祁蒲房滕屈饶解牟艾尤阳时穆农司卓古吉缪简车项连芦麦褚娄窦戚岑景党宫费卜冷晏席卫米柏宗瞿桂全佟应臧闵苟邬边卞姬师和仇栾隋商刁沙荣巫寇桑郎甄丛仲虞敖巩明佘池查麻苑迟邝"
        )
        let digits = Array(code)
        var cursor = 0
        var result = ""

        for position in 0..<6 {
            let usesStemOrBranch = position == 0 || position == 3
            let start = usesStemOrBranch ? cursor : cursor - 1
            let length = usesStemOrBranch ? 1 : 2
            guard start >= 0, start + length <= digits.count,
                  let index = Int(String(digits[start..<(start + length)]), radix: 16) else {
                return nil
            }
            let source = usesStemOrBranch ? heavenlyStemsAndBranches : surnames
            guard index < source.count else { return nil }
            result.append(source[index])
            cursor += 2
        }
        return result
    }

    private func plainText(_ value: String) -> String {
        decodedHTMLEntities(
            (try? SwiftSoup.parseBodyFragment(value).text()) ?? value
        )
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private func normalizedTopicListText(_ value: String) -> String {
        let text = plainText(value)
        return repairedUTF8TextMisdecodedAsGB18030(text) ?? text
    }

    private func repairedUTF8TextMisdecodedAsGB18030(_ value: String) -> String? {
        let rawEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        let encoding = String.Encoding(rawValue: rawEncoding)
        var bytes: [UInt8] = []
        var characterBoundaries = Set<Int>()

        for scalar in value.unicodeScalars {
            if !bytes.isEmpty {
                characterBoundaries.insert(bytes.count)
            }
            guard let encoded = String(scalar).data(using: encoding) else {
                return nil
            }
            bytes.append(contentsOf: encoded)
        }
        characterBoundaries.insert(bytes.count)

        guard let repaired = utf8String(
            restoringDropped80BytesIn: bytes,
            characterBoundaries: characterBoundaries,
            remainingInsertions: 8
        ),
        repaired != value else {
            return nil
        }

        let originalCount = value.unicodeScalars.count
        let repairedCount = repaired.unicodeScalars.count
        let containsPrivateUseScalar = value.unicodeScalars.contains {
            (0xE000...0xF8FF).contains($0.value)
        }
        guard repairedCount < originalCount,
              containsPrivateUseScalar || repairedCount * 4 <= originalCount * 3 else {
            return nil
        }
        return repaired
    }

    private func utf8String(
        restoringDropped80BytesIn bytes: [UInt8],
        characterBoundaries: Set<Int>,
        remainingInsertions: Int
    ) -> String? {
        if let decoded = String(bytes: bytes, encoding: .utf8) {
            return decoded
        }
        guard remainingInsertions > 0,
              let failure = incompleteUTF8Sequence(in: bytes),
              failure.missingContinuationCount <= remainingInsertions else {
            return nil
        }

        let candidates = characterBoundaries
            .filter { $0 >= failure.insertionRange.lowerBound && $0 <= failure.insertionRange.upperBound }
            .sorted()
        for insertionIndex in candidates {
            var repairedBytes = bytes
            repairedBytes.insert(
                contentsOf: repeatElement(UInt8(0x80), count: failure.missingContinuationCount),
                at: insertionIndex
            )
            let shiftedBoundaries = Set(characterBoundaries.map {
                $0 >= insertionIndex ? $0 + failure.missingContinuationCount : $0
            })
            if let decoded = utf8String(
                restoringDropped80BytesIn: repairedBytes,
                characterBoundaries: shiftedBoundaries,
                remainingInsertions: remainingInsertions - failure.missingContinuationCount
            ) {
                return decoded
            }
        }
        return nil
    }

    private func incompleteUTF8Sequence(
        in bytes: [UInt8]
    ) -> (insertionRange: ClosedRange<Int>, missingContinuationCount: Int)? {
        var index = 0
        while index < bytes.count {
            let lead = bytes[index]
            if lead < 0x80 {
                index += 1
                continue
            }

            let expectedContinuationCount: Int
            switch lead {
            case 0xC2...0xDF:
                expectedContinuationCount = 1
            case 0xE0...0xEF:
                expectedContinuationCount = 2
            case 0xF0...0xF4:
                expectedContinuationCount = 3
            default:
                return nil
            }

            var continuationCount = 0
            while continuationCount < expectedContinuationCount {
                let continuationIndex = index + 1 + continuationCount
                guard continuationIndex < bytes.count,
                      (0x80...0xBF).contains(bytes[continuationIndex]) else {
                    let failureIndex = min(continuationIndex, bytes.count)
                    return (
                        (index + 1)...failureIndex,
                        expectedContinuationCount - continuationCount
                    )
                }
                continuationCount += 1
            }

            let firstContinuation = bytes[index + 1]
            if (lead == 0xE0 && firstContinuation < 0xA0)
                || (lead == 0xED && firstContinuation > 0x9F)
                || (lead == 0xF0 && firstContinuation < 0x90)
                || (lead == 0xF4 && firstContinuation > 0x8F) {
                return nil
            }
            index += expectedContinuationCount + 1
        }
        return nil
    }

    private func decodedHTMLEntities(_ value: String) -> String {
        var decoded = value
        for _ in 0..<2 {
            guard decoded.contains("&"),
                  let next = try? Entities.unescape(decoded),
                  next != decoded else {
                break
            }
            decoded = next
        }
        return decoded
    }

    private func jsonPayload(in root: Any) -> Any {
        guard let dictionary = root as? [String: Any], let data = dictionary["data"] else {
            return root
        }
        return data
    }

    private func isKnownMessageEnvelope(_ value: Any) -> Bool {
        if value is [Any] { return true }
        guard let dictionary = value as? [String: Any] else { return false }
        return dictionary["0"] != nil
            || dictionary["nextPage"] != nil
            || dictionary["__ROWS"] != nil
            || dictionary["allmsgs"] != nil
    }

    private func throwJSONErrorIfPresent(in root: Any) throws {
        guard let dictionary = root as? [String: Any] else { return }
        let errorValue = dictionary["error"] ?? dictionary["__MESSAGE"]
        guard let errorValue, !(errorValue is NSNull) else { return }
        let message = concise(flattenedText(errorValue))
        guard !message.isEmpty else { return }
        if explicitlyRequiresLogin(message) {
            throw NGAServiceError.requiresLogin
        }
        if indicatesLockedTopic(message) {
            throw NGAServiceError.topicLocked
        }
        throw NGAServiceError.restricted(message)
    }

    private func indicatesLockedTopic(_ message: String) -> Bool {
        [
            "此帖子被锁定",
            "帖子被锁定",
            "帖子已锁定",
            "此主题被锁定",
            "主题被锁定",
            "主题已锁定"
        ].contains { message.contains($0) }
    }

    private func explicitlyRequiresLogin(_ message: String) -> Bool {
        [
            "未登录",
            "你必须登录",
            "必须先登录",
            "必须登录后",
            "请先登录",
            "登录后才能"
        ].contains { message.contains($0) }
    }

    private func jsonRoot(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func jsonRoot(_ text: String) -> Any? {
        text.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed])
        }
    }

    private func dictionaries(in value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] {
            return [dictionary] + dictionary.values.flatMap(dictionaries(in:))
        }
        if let array = value as? [Any] {
            return array.flatMap(dictionaries(in:))
        }
        return []
    }

    private func strings(in value: Any) -> [String] {
        if let string = value as? String {
            return [string]
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.flatMap(strings(in:))
        }
        if let array = value as? [Any] {
            return array.flatMap(strings(in:))
        }
        return []
    }

    private func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    private func marker(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let boolValue = value as? Bool { return boolValue }
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let stringValue = value as? String {
            let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !["0", "false", "no", "off"].contains(normalized)
        }
        return true
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let value = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return plainText(value)
    }

    private func int64(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private func int(_ value: Any?) -> Int? { int64(value).map(Int.init) }
    private func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return ["1", "true", "yes"].contains(value.lowercased()) }
        return false
    }
    private func url(_ value: Any?) -> URL? {
        guard let value = string(value), !value.isEmpty else { return nil }
        if value.hasPrefix("//") { return URL(string: "https:\(value)") }
        if let url = URL(string: value), url.scheme != nil { return secureURL(url) }
        return URL(string: value, relativeTo: NGAEndpoint.baseURL)?.absoluteURL
    }

    private func remoteResourceURL(_ rawValue: String?, kind: RemoteResourceKind) -> URL? {
        guard var rawValue else { return nil }
        rawValue = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        guard !rawValue.isEmpty else { return nil }

        if rawValue.hasPrefix("//"),
           let absolute = URL(string: "https:\(rawValue)") {
            return normalizedRemoteResourceURL(absolute, kind: kind)
        }
        if let absolute = URL(string: rawValue), absolute.scheme != nil {
            return normalizedRemoteResourceURL(absolute, kind: kind)
        }

        let withoutDot = rawValue
            .replacingOccurrences(of: #"^(?:\.\.?/)+"#, with: "", options: .regularExpression)
        switch kind {
        case .attachment:
            if withoutDot.hasPrefix("mon_") ||
                withoutDot.hasPrefix("attachments/") ||
                rawValue.hasPrefix("./") ||
                rawValue.hasPrefix("../") {
                let path = withoutDot.hasPrefix("attachments/")
                    ? String(withoutDot.dropFirst("attachments/".count))
                    : withoutDot
                return URL(string: "https://img.nga.cn/attachments/\(path)")
            }
        case .avatar:
            let path = withoutDot.hasPrefix("avatars/")
                ? String(withoutDot.dropFirst("avatars/".count))
                : withoutDot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !path.isEmpty {
                return URL(string: "https://img.nga.cn/avatars/\(path)")
            }
        }

        if rawValue.hasPrefix("/") {
            return URL(string: rawValue, relativeTo: NGAEndpoint.baseURL)?.absoluteURL
        }
        return URL(string: rawValue, relativeTo: NGAEndpoint.baseURL)?.absoluteURL
    }

    private func normalizedRemoteResourceURL(_ url: URL, kind: RemoteResourceKind) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        switch url.host?.lowercased() {
        case "img.nga.178.com":
            components?.host = "img.nga.cn"
        case "img4.nga.178.com":
            components?.host = "img4.nga.cn"
        case "img.ngacn.cc":
            if case .attachment = kind, url.path.hasPrefix("/attachments/") {
                components?.host = "img.nga.cn"
            }
        default:
            break
        }
        return components?.url
    }

    private func replacingMatches(
        in source: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: ([String]) -> String
    ) -> String {
        guard let expression = CachedRegularExpressions.shared.expression(pattern: pattern, options: options) else {
            return source
        }
        let original = source as NSString
        var result = source
        let matches = expression.matches(
            in: source,
            range: NSRange(location: 0, length: original.length)
        )
        for match in matches.reversed() {
            let captures: [String] = (1..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : original.substring(with: range)
            }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(captures))
        }
        return result
    }

    private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func htmlAttributeEscaped(_ value: String) -> String {
        htmlEscaped(value)
    }

    private func smileFile(family: String, name: String) -> String? {
        switch family.lowercased() {
        case "ac":
            let indexes: [String: Int] = [
                "blink": 0, "goodjob": 1, "上": 2, "中枪": 3, "偷笑": 4, "冷": 5,
                "凌乱": 6, "反对": 7, "吓": 8, "吻": 9, "呆": 10, "咦": 11,
                "哦": 12, "哭": 13, "哭1": 14, "哭笑": 15, "哼": 16, "喘": 17,
                "喷": 18, "嘲笑": 19, "嘲笑1": 20, "囧": 21, "委屈": 22, "心": 23,
                "忧伤": 24, "怒": 25, "怕": 26, "惊": 27, "愁": 28, "抓狂": 29,
                "抠鼻": 30, "擦汗": 31, "无语": 32, "晕": 33, "汗": 34, "瞎": 35,
                "羞": 36, "羡慕": 37, "花痴": 38, "茶": 39, "衰": 40, "计划通": 41,
                "赞同": 42, "闪光": 43, "黑枪": 44
            ]
            return indexes[name].map { "ac\($0).png" }
        case "a2":
            let indexes: [String: Int] = [
                "goodjob": 2, "偷笑": 3, "怒": 4, "诶嘿": 5, "笑": 7, "那个…": 8,
                "哦嗬嗬嗬": 9, "舔": 10, "有何贵干": 11, "病娇": 12, "lucky": 13,
                "鬼脸": 14, "大哭": 15, "冷": 16, "哭": 17, "妮可妮可妮": 18,
                "惊": 19, "poi": 20, "恨": 21, "囧2": 22, "中枪": 23, "囧": 24,
                "你看看你": 25, "yes": 26, "doge": 27, "自戳双目": 28, "偷吃": 30,
                "冷笑": 31, "壁咚": 32, "不活了": 33, "不明觉厉": 36, "jojo立": 37,
                "jojo立2": 38, "jojo立3": 39, "jojo立5": 40, "jojo立4": 41,
                "威吓": 42, "你已经死了": 45, "异议": 47, "认真": 48,
                "你这种人…": 49, "是在下输了": 51, "干杯": 52, "抢镜头": 52,
                "你为猴这么": 53
            ]
            return indexes[name].map { String(format: "a2_%02d.png", $0) }
        case "ng":
            let names = [
                "呲牙笑", "奸笑", "问号", "茶", "笑指", "燃尽", "晕", "扇笑", "寄",
                "别急", "doge", "丧", "汗", "呼", "叹气", "吃饼", "吃瓜", "吐舌",
                "哭", "喘", "心", "喷", "斜眼", "困", "大哭", "大惊", "害怕", "惊",
                "晕", "暴怒", "气愤", "热", "瓜不熟", "瞎", "色", "茶", "斜眼", "问号大"
            ]
            return names.lastIndex(of: name).map { "ng_\($0 + 1).png" }
        case "pst":
            let names = [
                "举手", "亲", "偷笑", "偷笑2", "偷笑3", "傻眼", "傻眼2", "兔子", "发光",
                "呆", "呆2", "呆3", "呕", "呵欠", "哭", "哭2", "哭3", "嘲笑", "基",
                "宅", "安慰", "幸福", "开心", "开心2", "开心3", "怀疑", "怒", "怒2",
                "怨", "惊吓", "惊吓2", "惊呆", "惊呆2", "惊呆3", "惨", "斜眼", "晕",
                "汗", "泪", "泪2", "泪3", "泪4", "满足", "满足2", "火星", "牙疼",
                "电击", "看戏", "眼袋", "眼镜", "笑而不语", "紧张", "美味", "背",
                "脸红", "脸红2", "腐", "星星眼", "谢", "醉", "闷", "闷2", "音乐",
                "黑脸", "鼻血"
            ]
            return names.firstIndex(of: name).map { String(format: "pt%02d.png", $0) }
        case "dt":
            let names = [
                "ROLL", "上", "傲娇", "叉出去", "发光", "呵欠", "哭", "啃古头", "嘲笑",
                "心", "怒", "怒2", "怨", "惊", "惊2", "无语", "星星眼", "星星眼2",
                "晕", "注意", "注意2", "泪", "泪2", "烧", "笑", "笑2", "笑3", "脸红",
                "药", "衰", "鄙视", "闲", "黑脸"
            ]
            return names.firstIndex(of: name).map { String(format: "dt%02d.png", $0 + 1) }
        case "pg":
            let names = [
                "战斗力", "哈啤", "满分", "衰", "拒绝", "心", "严肃", "吃瓜",
                "嘣", "嘣2", "冻", "谢", "哭", "响指", "转身"
            ]
            return names.firstIndex(of: name).map { String(format: "pg%02d.png", $0 + 1) }
        default:
            return nil
        }
    }

    private func date(_ value: Any?) -> Date? {
        guard let timestamp = int64(value), timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private func ngaDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return date
            }
        }
        return nil
    }

    private func unique<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
        var seen = Set<T.ID>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private func absoluteURL(_ value: String, relativeTo baseURL: URL) -> URL? {
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private func queryInt64(_ name: String, in url: URL) -> Int64? {
        URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?.first(where: { $0.name == name })?.value.flatMap(Int64.init)
    }

    private func digits(in value: String) -> String? {
        let digits = value.filter(\.isNumber)
        return digits.isEmpty ? nil : digits
    }

    private func stableID(for value: String) -> Int64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int64(bitPattern: hash)
    }

    private func extractAuthor(from text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).first(where: { !$0.isEmpty }) ?? ""
    }

    private func extractReplyCount(from text: String) -> Int {
        let values = text.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        return values.last ?? 0
    }

    private func kind(from value: String, folder: MessageFolder) -> ForumMessageKind {
        let lower = value.lowercased()
        if folder != .notifications { return .privateMessage }
        if lower.contains("引用") || lower.contains("quote") { return .quote }
        if lower.contains("评价") || lower.contains("评论") || lower.contains("comment") { return .comment }
        if lower.contains("@") || lower.contains("mention") { return .mention }
        if lower.contains("回复") || lower.contains("reply") { return .reply }
        return .unknown
    }

    private func flattenedText(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let dictionary = value as? [String: Any] { return dictionary.values.map(flattenedText).joined(separator: " ") }
        if let array = value as? [Any] { return array.map(flattenedText).joined(separator: " ") }
        return ""
    }

    private func flattenedStringText(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.map(flattenedStringText).filter { !$0.isEmpty }.joined(separator: " ")
        }
        if let array = value as? [Any] {
            return array.map(flattenedStringText).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return ""
    }

    private func concise(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(160))
    }
}
