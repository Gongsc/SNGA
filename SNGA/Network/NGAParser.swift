import Foundation
import SwiftSoup

struct ParsedHTMLForm: Sendable {
    var action: URL
    var fields: [String: String]
}

struct NGAParser: Sendable {
    func profile(from response: NGAHTTPResponse, expectedUID: Int64) throws -> Profile {
        let text = try response.decodedString()
        if let root = jsonRoot(response.data) ?? jsonRoot(text) {
            try throwJSONErrorIfPresent(in: root)
            for dictionary in dictionaries(in: root) {
                let uid = int64(dictionary["uid"]) ?? int64(dictionary["id"])
                let name = string(dictionary["username"]) ?? string(dictionary["name"])
                if uid == expectedUID, let name, !name.isEmpty {
                    let masked = name == "UID\(expectedUID)"
                    return Profile(
                        uid: expectedUID,
                        displayName: masked ? "NGA \(expectedUID)" : plainText(name),
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
                let message = string(root["msg"]) ?? "板块目录请求失败（代码 \(code)）"
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
                    throw NGAServiceError.unexpectedPage("官方板块目录返回为空")
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
        guard !result.isEmpty else { throw NGAServiceError.unexpectedPage("未找到板块目录") }
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
            throw NGAServiceError.unexpectedPage("未找到账号收藏板块")
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
        guard !topics.isEmpty else { throw NGAServiceError.unexpectedPage("未找到主题列表") }
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
            let topic = topicMetadata.flatMap {
                parseTopic(from: $0, fallbackForumID: ForumID(rawValue: 0))
            }
                ?? dictionaries(in: root)
                    .compactMap { parseTopic(from: $0, fallbackForumID: ForumID(rawValue: 0)) }
                    .first { $0.id == topicID }
                ?? Topic(id: topicID, forumID: ForumID(rawValue: 0), subject: "帖子 \(topicID.rawValue)", author: "", replyCount: 0, isPinned: false, isLocked: false)
            var users = payload
                .flatMap { $0["__U"] }
                .map { userMap(in: $0) }
                ?? postUsers(in: root)
            if let topicMetadata,
               let authorUID = postAuthorID(in: topicMetadata),
               let author = normalizedUsername(string(topicMetadata["author"])) {
                let existingAvatar = users[authorUID]?.avatarURL
                users[authorUID] = PostUser(name: author, avatarURL: existingAvatar)
            }
            let posts = postDictionaries(in: root, payload: payload).compactMap { dictionary in
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
                let totalPages = threadPageCount(topic: topic, currentPage: page, postCount: posts.count)
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
        var posts: [Post] = []
        let rows = try document.select("tr.postrow, .postrow, .post-row")
        if !rows.isEmpty {
            for row in rows {
                guard let floor = try htmlFloor(in: row) else { continue }
                let metadata = htmlPostMetadata[floor]
                let content = try row.select(
                    "#postcontent\(floor), #post_content\(floor), [id^='postcontent'], [id^='post_content'], .postcontent, .postContent"
                ).first
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
                    postedAt: metadata?.postedAt,
                    html: contentHTML,
                    upvoteCount: metadata?.upvoteCount ?? 0,
                    downvoteCount: metadata?.downvoteCount ?? 0
                ))
            }
        } else {
            var fallbackID: Int64 = Int64(page * 10_000)
            let candidates = try document.select(
                "[id^='postcontent'], [id^='post_content'], .postcontent, .postContent"
            )
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
                    html: try element.html()
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
            replyCount: max(0, posts.map(\.floor).max() ?? 0),
            isPinned: false,
            isLocked: false
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
        let totalPages = max(
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
        // NGA 每页最多显示 20 个楼层；replyCount 不包含主题首帖。
        let countFromReplies = max(1, (topic.replyCount + 20) / 20)
        if topic.replyCount > 0 || postCount < 20 {
            return max(currentPage, countFromReplies)
        }
        // 结构化响应缺少主题元数据时，只能用满页结果保守探测下一页。
        return currentPage + 1
    }

    func messages(from response: NGAHTTPResponse, folder: MessageFolder, page: Int) throws -> MessagePage {
        if let root = jsonRoot(response.data) {
            try throwJSONErrorIfPresent(in: root)
            let payload = jsonPayload(in: root)
            var values: [ForumMessage]
            if folder == .notifications {
                values = dictionaries(in: payload)
                    .compactMap(notificationMessage(from:))
                    .filter { $0.kind != .privateMessage }
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
                return MessagePage(folder: folder, messages: unique(values), page: page, hasMore: values.count >= 20)
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
                    let sender = items.compactMap { dictionary -> String? in
                        if let value = normalizedUsername(string(dictionary["from_username"])) {
                            return value
                        }
                        return int64(dictionary["from"]).flatMap { users[$0]?.name }
                    }.first ?? ""
                    let articles = items.map { dictionary in
                        let uid = int64(dictionary["from"]) ?? int64(dictionary["from_uid"])
                        let name = normalizedUsername(string(dictionary["from_username"]))
                            ?? uid.flatMap { users[$0]?.name }
                            ?? "未知用户"
                        let content = string(dictionary["content"]) ?? ""
                        return """
                        <article>
                          <header><strong>\(htmlEscaped(name))</strong></header>
                          <div>\(content)</div>
                        </article>
                        """
                    }
                    return ForumMessage(
                        id: id,
                        kind: .privateMessage,
                        sender: sender,
                        subject: subject,
                        preview: items.last.flatMap { string($0["content"]) } ?? "",
                        html: articles.joined(separator: "<hr>"),
                        sentAt: items.last.flatMap { date($0["time"]) },
                        isUnread: false,
                        replyURL: response.url
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
            replyURL: replyLink
        )
    }

    func checkIn(from response: NGAHTTPResponse) throws -> CheckInResult {
        let text = try response.decodedString()
        if let root = jsonRoot(response.data) ?? jsonRoot(text) {
            let message = flattenedText(root)
            if message.contains("已签到") || message.contains("已经签到") || message.contains("今天已经签到") {
                return .alreadyCheckedIn(message: checkInAlreadyCompletedMessage(from: message))
            }
            if message.localizedCaseInsensitiveContains("client error") {
                throw NGAServiceError.restricted("签到请求被 NGA 拒绝，请稍后重试")
            }
            try throwJSONErrorIfPresent(in: root)
            if message.contains("成功") || (message.contains("签到") && !message.contains("失败")) {
                return .success(message: concise(message))
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
            return .success(message: concise(message))
        }
        throw NGAServiceError.unexpectedPage("无法确认签到结果")
    }

    private func checkInAlreadyCompletedMessage(from source: String) -> String {
        let message = concise(source)
        guard let expression = try? NSRegularExpression(
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
        guard let envelopeExpression = try? NSRegularExpression(
            pattern: #"<__MESSAGE\b[^>]*>([\s\S]*?)</__MESSAGE>"#,
            options: .caseInsensitive
        ) else { return [] }
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let envelopeMatch = envelopeExpression.firstMatch(in: source, range: sourceRange),
              let envelopeRange = Range(envelopeMatch.range(at: 1), in: source) else {
            return []
        }
        let envelope = String(source[envelopeRange])
        guard let itemExpression = try? NSRegularExpression(
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

    func sanitizedPostHTML(_ source: String) -> String {
        let rendered = renderBBCode(source)
        var clean: String
        do {
            let document = try SwiftSoup.parseBodyFragment(rendered, NGAEndpoint.baseURL.absoluteString)
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
                    try image.attr("loading", "lazy")
                    try image.attr("referrerpolicy", "no-referrer")
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

            let whitelist = try Whitelist.relaxed()
                .addTags("details", "summary", "section", "hr")
                .addAttributes("a", "class")
                .addAttributes("img", "class", "loading", "referrerpolicy")
                .addAttributes("span", "class")
                .addAttributes("div", "class")
                .addAttributes("h3", "class")
                .addAttributes("section", "class")
                .addAttributes("details", "open")
                .addAttributes("td", "width")
                .addAttributes("th", "width")
            clean = try SwiftSoup.clean(
                try document.body()?.html() ?? rendered,
                NGAEndpoint.baseURL.absoluteString,
                whitelist
            ) ?? "<p>内容无法显示</p>"
            clean = compactedPostSpacing(clean)
        } catch {
            clean = "<p>内容无法显示</p>"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; font-src 'none'; media-src https:">
        <style>
        :root{color-scheme:light dark;--snga-accent:#b06d00;--snga-highlight:#d59b3a;--snga-smile-backdrop-system:transparent;--snga-smile-backdrop:var(--snga-smile-backdrop-system)}@media(prefers-color-scheme:dark){:root{--snga-smile-backdrop-system:rgba(255,255,255,.88)}}html,body{width:100%;max-width:100%;overflow-x:hidden;overflow-y:hidden}body{font:14px -apple-system,BlinkMacSystemFont,sans-serif;margin:0;color:CanvasText;background:transparent;overflow-wrap:anywhere;line-height:1.55}
        #snga-post-content{display:flow-root;width:100%;max-width:100%;min-height:1px}#snga-post-content>:first-child{margin-top:0}#snga-post-content>:last-child{margin-bottom:0}p{margin:6px 0}
        img{max-width:100%;height:auto;vertical-align:middle}.nga-smile{max-width:64px;max-height:64px;background:var(--snga-smile-backdrop);border-radius:6px}table{max-width:100%;border-collapse:collapse;display:block;overflow:auto}td,th{border:1px solid color-mix(in srgb,CanvasText 20%,transparent);padding:4px}
        ul,ol{margin:8px 0;padding-left:1.6em}li{margin:4px 0}hr{height:1px;margin:12px 0;border:0;background:color-mix(in srgb,CanvasText 22%,transparent)}
        blockquote{margin:8px 0;padding:6px 10px;border-left:3px solid var(--snga-highlight);background:color-mix(in srgb,CanvasText 7%,transparent)}a{color:var(--snga-accent)}.nga-post-reference{display:inline-block;font-weight:600;text-decoration:none;border-bottom:1px dashed currentColor}pre,code{white-space:pre-wrap}
        details{margin:8px 0;padding:6px 10px;border:1px solid color-mix(in srgb,CanvasText 18%,transparent);border-radius:6px}summary{cursor:pointer;font-weight:600}.nga-section-title{margin:14px 0 8px;font-size:1.15em}
        .nga-rich-card{margin:8px 0 12px;padding:12px;border:1px solid color-mix(in srgb,CanvasText 14%,transparent);border-radius:10px;background:color-mix(in srgb,var(--snga-highlight) 8%,transparent)}
        .nga-rich-card-title{margin:0 0 8px;font-size:1.15em}.nga-rich-card-image{margin:6px 0}.nga-rich-card-image img{display:block;border-radius:7px}
        .ubb-color-red{color:red}.ubb-color-orange{color:orange}.ubb-color-green{color:green}.ubb-color-teal{color:teal}.ubb-color-blue{color:blue}.ubb-color-skyblue{color:skyblue}.ubb-color-royalblue{color:royalblue}.ubb-color-purple{color:purple}.ubb-color-deeppink{color:deeppink}.ubb-color-chocolate{color:chocolate}.ubb-color-sienna{color:sienna}.ubb-color-gray{color:gray}
        .ubb-size-100{font-size:100%}.ubb-size-110{font-size:110%}.ubb-size-120{font-size:120%}.ubb-size-130{font-size:130%}.ubb-size-140{font-size:140%}.ubb-size-150{font-size:150%}
        .ubb-align-left{text-align:left}.ubb-align-center{text-align:center}.ubb-align-right{text-align:right}
        </style></head><body><main id="snga-post-content">\(clean)</main></body></html>
        """
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

    private func renderBBCode(_ source: String) -> String {
        var output = source

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
            let url = "https://img4.nga.178.com/ngabbs/post/smile/\(file)"
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
        output = replacingMatches(
            in: output,
            pattern: #"\[quote[^\]]*\](.*?)\[/quote\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { captures in
            "<blockquote>\(captures.first ?? "")</blockquote>"
        }
        output = renderListBBCode(output)
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
                "red", "orange", "green", "teal", "blue", "skyblue",
                "royalblue", "purple", "deeppink", "chocolate", "sienna", "gray"
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
            pattern: #"\[size=(\d{2,3})%\]"#,
            options: [.caseInsensitive]
        ) { captures in
            let value = Int(captures.first ?? "").map { min(150, max(100, $0)) } ?? 100
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
        return output.replacingOccurrences(
            of: #"(?i)(?:\s*<br\s*/?>\s*){3,}"#,
            with: "<br><br>",
            options: .regularExpression
        )
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
                let totalWidth = widths.reduce(0, +)
                var renderedRow = replacingMatches(
                    in: row,
                    pattern: #"\[(td|th)(?:\s+([^\]]*))?\](.*?)\[/\1\]"#,
                    options: [.caseInsensitive, .dotMatchesLineSeparators]
                ) { cellCaptures in
                    guard cellCaptures.count == 3 else { return "" }
                    let tag = cellCaptures[0].lowercased()
                    let width = tableCellWidth(in: cellCaptures[1])
                    let widthAttribute: String
                    if let width, totalWidth > 0 {
                        let percentage = width / totalWidth * 100
                        widthAttribute = #" width="\#(formattedPercentage(percentage))%""#
                    } else {
                        widthAttribute = ""
                    }
                    return "<\(tag)\(widthAttribute)>\(cellCaptures[2])</\(tag)>"
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

    private func tableCellWidths(in row: String) -> [Double] {
        guard let expression = try? NSRegularExpression(
            pattern: #"\[(?:td|th)\b([^\]]*)\]"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let source = row as NSString
        return expression.matches(
            in: row,
            range: NSRange(location: 0, length: source.length)
        ).compactMap { match in
            guard match.numberOfRanges > 1,
                  match.range(at: 1).location != NSNotFound else {
                return nil
            }
            return tableCellWidth(in: source.substring(with: match.range(at: 1)))
        }
    }

    private func tableCellWidth(in attributes: String) -> Double? {
        guard let expression = try? NSRegularExpression(
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
            isSelectedInParent: selectedSubforumState(from: dictionary)
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
        return components.url
    }

    private func secureURL(_ value: URL) -> URL? {
        guard value.scheme == "http" else { return value }
        var components = URLComponents(url: value, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url
    }

    private func parseTopic(from dictionary: [String: Any], fallbackForumID: ForumID) -> Topic? {
        guard let tid = int64(dictionary["tid"]),
              let rawSubject = string(dictionary["subject"]) else { return nil }
        let subject = plainText(rawSubject)
        guard !subject.isEmpty else { return nil }
        let sourceForum = topicSourceForum(in: dictionary)
        let mirroredForumID = mirroredForumID(in: dictionary)
        return Topic(
            id: TopicID(rawValue: tid),
            forumID: ForumID(rawValue: int64(dictionary["fid"]) ?? fallbackForumID.rawValue),
            subject: subject,
            author: normalizedUsername(string(dictionary["author"])) ?? "",
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
                || (int(dictionary["favorite"]) ?? 0) > 0
        )
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
            let attributes = fields.count > 4 ? int(fields[4]) : nil
            return Forum(
                id: id,
                name: name,
                subtitle: subtitle,
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
        return (id, parentID, string(parent["2"]).map(plainText))
    }

    private struct PostUser {
        var name: String
        var avatarURL: URL?
    }

    private struct HTMLPostMetadata {
        var pid: Int64?
        var authorUID: Int64?
        var postedAt: Date?
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
            result[floor] = HTMLPostMetadata(
                pid: Int64(normalizedJavaScriptLiteral(arguments[10])),
                authorUID: Int64(normalizedJavaScriptLiteral(arguments[13])),
                postedAt: timestamp.flatMap {
                    $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
                },
                upvoteCount: max(0, score),
                downvoteCount: max(0, -score)
            )
        }
        return result
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
        // NGA 的结构化响应以 pid=0 表示主题首帖。少数页面变体会把 lou
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
        return Post(
            id: PostID(rawValue: pid),
            topicID: TopicID(rawValue: int64(dictionary["tid"]) ?? topicID.rawValue),
            floor: floor,
            author: author,
            authorUID: authorUID,
            avatarURL: inlineAvatar ?? user?.avatarURL,
            postedAt: date(dictionary["postdatetimestamp"]) ?? date(dictionary["postdate"]),
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
            userVote: int(dictionary["user_vote"]).flatMap(voteDirection)
        )
    }

    private func referencedPostID(in content: String) -> Int64? {
        guard let expression = try? NSRegularExpression(
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
        guard let value = dictionaries(in: root).first(where: { $0["__U"] != nil })?["__U"] else {
            return [:]
        }
        return userMap(in: value)
    }

    private func userMap(in value: Any) -> [Int64: PostUser] {
        var result: [Int64: PostUser] = [:]
        var nextAnonymousUID: Int64 = -1

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
                    result[resolvedUID] = PostUser(
                        name: name,
                        avatarURL: remoteResourceURL(string(dictionary["avatar"]), kind: .avatar)
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
        guard let rawType = int(dictionary["0"]),
              let timestamp = int64(dictionary["9"]) else { return nil }
        let sender = normalizedUsername(string(dictionary["2"])) ?? ""
        let subject = string(dictionary["5"]).map(plainText) ?? "论坛提醒"
        let topicID = int64(dictionary["6"]).map(TopicID.init(rawValue:))
        let postID = int64(dictionary["8"])
        let kind: ForumMessageKind
        switch rawType {
        case 1, 2: kind = .reply
        case 7, 8: kind = .mention
        case 10, 11: kind = .privateMessage
        default: kind = .unknown
        }
        let identity = [
            String(timestamp),
            String(rawType),
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
            subject: subject.isEmpty ? kind.notificationTitle : subject,
            preview: kind.notificationTitle,
            sentAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            isUnread: bool(dictionary["unread"])
                || (int(dictionary["read"]) == 0),
            topicID: topicID,
            replyURL: components?.url
        )
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
        throw NGAServiceError.restricted(message)
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

        if rawValue.hasPrefix("//") {
            return URL(string: "https:\(rawValue)")
        }
        if let absolute = URL(string: rawValue), absolute.scheme != nil {
            guard ["http", "https"].contains(absolute.scheme?.lowercased() ?? "") else { return nil }
            return secureURL(absolute)
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
                return URL(string: "https://img.nga.178.com/attachments/\(path)")
            }
        case .avatar:
            let path = withoutDot.hasPrefix("avatars/")
                ? String(withoutDot.dropFirst("avatars/".count))
                : withoutDot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !path.isEmpty {
                return URL(string: "https://img.nga.178.com/avatars/\(path)")
            }
        }

        if rawValue.hasPrefix("/") {
            return URL(string: rawValue, relativeTo: NGAEndpoint.baseURL)?.absoluteURL
        }
        return URL(string: rawValue, relativeTo: NGAEndpoint.baseURL)?.absoluteURL
    }

    private func replacingMatches(
        in source: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: ([String]) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
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

    private func concise(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(160))
    }
}
