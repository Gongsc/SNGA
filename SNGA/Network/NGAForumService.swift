import Foundation

actor LiveNGAForumService: NGAForumService {
    nonisolated let accountID: AccountID
    private let client: NGANetworkClient
    private let parser: NGAParser

    init(
        accountID: AccountID,
        cookies: [SessionCookie],
        transport: any HTTPTransport = URLSessionTransport(),
        cookieDidChange: @escaping @Sendable ([SessionCookie]) async -> Void = { _ in }
    ) {
        self.accountID = accountID
        self.client = NGANetworkClient(cookies: cookies, transport: transport, cookieDidChange: cookieDidChange)
        self.parser = NGAParser()
    }

    func profile(uid: Int64) async throws -> Profile {
        try parser.profile(from: await client.request(.profile(uid: uid)), expectedUID: uid)
    }

    func userActivities(uid: Int64, kind: UserActivityKind, page: Int) async throws -> UserActivityPage {
        try parser.userActivities(
            from: await client.request(.userActivities(uid: uid, kind: kind, page: page)),
            uid: uid,
            kind: kind,
            page: page
        )
    }

    func forums() async throws -> [Forum] {
        try parser.forums(from: await client.request(.forums))
    }

    func topics(forumID: ForumID, page: Int) async throws -> ForumPage {
        try parser.forumPage(from: await client.request(.topics(forumID: forumID, page: page)), forumID: forumID, page: page)
    }

    func threadPage(topicID: TopicID, page: Int) async throws -> ThreadPage {
        var result: ThreadPage
        do {
            result = try parser.threadPage(
                from: await client.request(.thread(topicID: topicID, page: page)),
                topicID: topicID,
                page: page
            )
        } catch let error as NGAServiceError {
            switch error {
            case .unexpectedPage, .restricted:
                result = try parser.threadPage(
                    from: await client.request(.threadHTML(topicID: topicID, page: page)),
                    topicID: topicID,
                    page: page
                )
            default:
                throw error
            }
        }
        result.posts = result.posts.map { post in
            var post = post
            post.html = parser.sanitizedPostHTML(
                post.html,
                topicRating: post.floor == 0 ? result.topic.rating : nil
            )
            return post
        }
        result.hotReplies = result.hotReplies.map { post in
            var post = post
            post.html = parser.sanitizedPostHTML(post.html)
            return post
        }
        return result
    }

    func submitReply(topicID: TopicID, submission: ReplySubmission) async throws -> PostID? {
        let preflightEndpoint = NGAEndpoint.replyForm(topicID: topicID, replyTo: submission.replyTo)
        let preflight = try await client.request(preflightEndpoint)
        var form = try parser.form(from: preflight, requiredField: "post_content")
        form.fields["post_content"] = submission.content
        form.fields["step"] = form.fields["step"] ?? "2"
        if let replyTo = submission.replyTo {
            form.fields["pid"] = form.fields["pid"] ?? replyTo.description
        }
        for (dimensionID, score) in submission.ratingScores {
            guard Int64(dimensionID).map({ $0 > 0 }) == true else {
                throw NGAServiceError.unsupported("评分维度无效")
            }
            form.fields[dimensionID] = score.description
        }
        let response = try await client.request(try postEndpoint(for: form, referer: preflight.url))
        return try parser.submissionSucceeded(from: response)
    }

    func vote(topicID: TopicID, postID: PostID, direction: PostVoteDirection) async throws -> PostVoteState {
        try parser.voteState(from: await client.request(.vote(
            topicID: topicID,
            postID: postID,
            direction: direction
        )))
    }

    func submitTopicPollVote(topicID: TopicID, optionIDs: [String]) async throws {
        guard !optionIDs.isEmpty else {
            throw NGAServiceError.unsupported("请至少选择一个投票选项")
        }
        let response = try await client.request(.topicPollVote(
            topicID: topicID,
            optionIDs: optionIDs
        ))
        try parser.actionSucceeded(from: response)
    }

    func messages(folder: MessageFolder, page: Int) async throws -> MessagePage {
        try parser.messages(from: await client.request(.messages(folder: folder, page: page)), folder: folder, page: page)
    }

    func message(id: MessageID) async throws -> ForumMessage {
        let response = try await client.request(.message(id: id))
        var message = try parser.message(from: response, id: id)
        if let html = message.html {
            message.html = parser.sanitizedPostHTML(html)
        }
        message.posts = message.posts.map { post in
            var post = post
            post.html = parser.sanitizedPostHTML(post.html)
            return post
        }
        return message
    }

    func replyMessage(id: MessageID, content: String) async throws {
        let response = try await client.request(.replyMessage(id: id, content: content))
        try parser.actionSucceeded(from: response)
    }

    func favorites() async throws -> [Forum] {
        do {
            return try parser.favoriteForums(from: await client.request(.favorites))
        } catch let error as NGAServiceError where error == .requiresLogin {
            throw error
        } catch {
            // 一些账号仍返回旧版网页收藏结构，保留官网旧接口作为只读兼容路径。
            return try parser.favoriteForums(from: await client.request(.legacyFavorites))
        }
    }

    func updateFavorite(forumID: ForumID, isFavorite: Bool) async throws {
        do {
            let response = try await client.request(.updateFavorite(forumID: forumID, isFavorite: isFavorite))
            try parser.actionSucceeded(from: response)
        } catch NGAServiceError.server(404) {
            // 只有在服务器明确表示当前路由不存在时才切旧协议，避免不明确结果下重复写入。
            let response = try await client.request(.updateFavorite(forumID: forumID, isFavorite: isFavorite, legacy: true))
            try parser.actionSucceeded(from: response)
        }
    }

    func favoriteTopicFolders() async throws -> [TopicFavoriteFolder] {
        try parser.favoriteTopicFolders(
            from: await client.request(.favoriteTopicFolders)
        )
    }

    func favoriteTopics(folderID: String, page: Int) async throws -> ForumPage {
        try parser.favoriteTopicPage(
            from: await client.request(.favoriteTopics(folderID: folderID, page: page)),
            page: page
        )
    }

    func updateTopicFavorite(
        topicID: TopicID,
        folderID: String,
        isFavorite: Bool
    ) async throws {
        let response = try await client.request(.updateTopicFavorite(
            topicID: topicID,
            folderID: folderID,
            isFavorite: isFavorite
        ))
        try parser.actionSucceeded(from: response)
    }

    func createTopicFavoriteFolder(
        name: String,
        isPublic: Bool,
        isDefault: Bool
    ) async throws -> String? {
        let response = try await client.request(.createTopicFavoriteFolder(
            name: name,
            isPublic: isPublic,
            isDefault: isDefault
        ))
        return try parser.createdTopicFavoriteFolderID(from: response)
    }

    func updateTopicFavoriteFolder(_ folder: TopicFavoriteFolder) async throws {
        let response = try await client.request(.updateTopicFavoriteFolder(folder))
        try parser.actionSucceeded(from: response)
    }

    func deleteTopicFavoriteFolder(folderID: String) async throws {
        let response = try await client.request(.deleteTopicFavoriteFolder(folderID: folderID))
        try parser.actionSucceeded(from: response)
    }

    func checkIn() async throws -> CheckInResult {
        try parser.checkIn(from: await client.request(.checkIn))
    }

    private func getEndpoint(for url: URL) throws -> NGAEndpoint {
        try validateNGA(url)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        return NGAEndpoint(path: url.path, queryItems: components?.queryItems ?? [])
    }

    private func postEndpoint(for form: ParsedHTMLForm, referer: URL) throws -> NGAEndpoint {
        try validateNGA(form.action)
        let components = URLComponents(url: form.action, resolvingAgainstBaseURL: true)
        return NGAEndpoint(
            path: form.action.path,
            queryItems: components?.queryItems ?? [],
            method: .post,
            form: form.fields,
            referer: referer,
            isWrite: true,
            userAgentOverride: "NGA_WP_JW/(;WINDOWS)"
        )
    }

    private func validateNGA(_ url: URL) throws {
        guard url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "nga.cn" || host.hasSuffix(".nga.cn") else {
            throw NGAServiceError.restricted("已阻止向非 NGA 地址提交数据")
        }
    }
}
