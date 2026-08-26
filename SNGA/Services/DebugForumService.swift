#if DEBUG
import Foundation

actor DebugForumService: ForumService {
    nonisolated let accountID: AccountID
    nonisolated let site: ForumSite = .nga
    /// 可注入：用来验「站点缺某个能力时会怎样」，而不必等真适配器写出来。
    nonisolated let capabilities: ForumCapabilities
    private var isCheckedInToday = false
    private var checkInRequestCount = 0
    private var checkInStatusRequestCount = 0
    private let forum = Forum(
        id: ForumID(nga: -7),
        name: "艾泽拉斯国家地理",
        subtitle: "UI 测试版面",
        pinnedTopicID: TopicID(rawValue: 9003)
    )

    init(accountID: AccountID, capabilities: ForumCapabilities = .all) {
        self.accountID = accountID
        self.capabilities = capabilities
    }

    func currentUserID() async throws -> Int64 { 10001 }

    func profile(uid: Int64) async throws -> Profile {
        Profile(
            uid: uid,
            displayName: "测试账号",
            avatarURL: nil,
            userGroup: "学徒",
            registeredAt: Date(timeIntervalSince1970: 1_435_199_662),
            postCount: 394,
            location: "浙江省",
            signature: "这是一条测试签名",
            reputation: 1.5,
            fame: 15,
            money: 168,
            followerCount: 6
        )
    }

    func userActivities(uid: Int64, kind: UserActivityKind, page: Int) async throws -> UserActivityPage {
        let values = [
            UserActivity(
                id: "\(kind.rawValue)-9001",
                kind: kind,
                topicID: TopicID(rawValue: 9001),
                forumID: forum.id,
                forumName: forum.name,
                subject: "话题一：欢迎使用 SNGA",
                excerpt: kind == .replies ? "这是一条用于 UI 测试的用户回复摘要。" : nil,
                postedAt: Date(timeIntervalSince1970: 1_785_000_000)
            )
        ]
        return UserActivityPage(
            kind: kind,
            activities: values,
            page: page,
            hasMore: page < 2,
            totalPages: 2
        )
    }

    func forums() async throws -> [Forum] {
        [
            Forum(
                id: forum.id,
                name: forum.name,
                subtitle: forum.subtitle,
                category: "网事杂谈",
                pinnedTopicID: forum.pinnedTopicID
            ),
            Forum(id: ForumID(nga: 510381), name: "晴风村", category: "手机游戏")
        ]
    }

    func search(
        _ request: ForumSearchRequest,
        page: Int
    ) async throws -> ForumSearchPage {
        let targetPage = max(1, page)
        switch request.kind {
        case .topicSubject, .topicContent:
            let resultForumID = request.forumID ?? forum.id
            return ForumSearchPage(
                request: request,
                topics: [
                    Topic(
                        id: TopicID(rawValue: 9101),
                        forumID: resultForumID,
                        subject: "搜索结果：\(request.query)",
                        author: "搜索测试用户",
                        replyCount: 6,
                        sourceForumName: request.forumID == nil ? forum.name : nil
                    )
                ],
                page: targetPage,
                hasMore: targetPage < 2,
                totalPages: 2
            )
        case .forum:
            return ForumSearchPage(
                request: request,
                forums: [
                    Forum(
                        id: forum.id,
                        name: "\(request.query) · \(forum.name)",
                        subtitle: forum.subtitle
                    )
                ]
            )
        case .user:
            return ForumSearchPage(
                request: request,
                users: [try await profile(uid: 42)]
            )
        case .userTopics, .userContent:
            let kind = request.kind.userActivityKind ?? .topics
            let result = try await userActivities(
                uid: 42,
                kind: kind,
                page: targetPage
            )
            return ForumSearchPage(
                request: request,
                users: [try await profile(uid: 42)],
                activities: result.activities,
                page: result.page,
                hasMore: result.hasMore,
                totalPages: result.totalPages
            )
        }
    }

    func topics(
        forumID: ForumID,
        page: Int,
        sortOrder: TopicListSortOrder,
        featuredOnly: Bool
    ) async throws -> ForumPage {
        // Keep the UI-test response pending long enough to verify refresh animations.
        try await Task.sleep(for: .seconds(2))
        let topics = [
            Topic(id: TopicID(rawValue: 9001), forumID: forumID, subject: "话题一：欢迎使用 SNGA", author: "测试用户", authorUID: 1001, replyCount: 2),
            Topic(id: TopicID(rawValue: 9002), forumID: forumID, subject: "话题二：多账号与收藏测试", author: "另一位用户", authorUID: 1002, replyCount: 8)
        ]
        let sortedTopics = sortOrder == .latestReply
            ? topics
            : Array(topics.reversed())
        return ForumPage(
            forum: forum,
            topics: featuredOnly
                ? sortedTopics.filter { $0.id == TopicID(rawValue: 9002) }
                : sortedTopics,
            page: page,
            hasMore: featuredOnly ? false : page < 3,
            totalPages: featuredOnly ? 1 : 3
        )
    }

    func threadPage(
        topicID: TopicID,
        page: Int,
        authorUID: Int64?
    ) async throws -> ThreadPage {
        // Keep UI-test responses pending long enough to observe thread skeleton transitions.
        try await Task.sleep(for: .seconds(1))
        let isPrimaryTopic = topicID == TopicID(rawValue: 9001)
        let isPinnedTopic = topicID == forum.pinnedTopicID
        let subject: String
        if isPrimaryTopic {
            subject = "话题一：欢迎使用 SNGA"
        } else if isPinnedTopic {
            subject = "版面置顶话题"
        } else {
            subject = "话题二：多账号与收藏测试"
        }
        let topic = Topic(
            id: topicID,
            forumID: forum.id,
            subject: subject,
            author: "测试用户",
            authorUID: isPrimaryTopic ? 1001 : 1002,
            replyCount: 1,
            isPinned: isPinnedTopic,
            rating: isPrimaryTopic
                ? TopicRating(
                    id: topicID,
                    dimensions: [
                        TopicRatingDimension(
                            id: "100",
                            title: "客户端体验",
                            ratingCount: 30,
                            totalScore: 234
                        )
                    ],
                    minimumScore: 1,
                    maximumScore: 10,
                    endsAt: Date(timeIntervalSince1970: 1_893_427_200),
                    participantCount: 30
                )
                : nil
        )
        let firstPostHTML = isPrimaryTopic
            ? """
              <p>这是一条用于 UI 测试的帖子内容。</p>
              <p><a href="https://bbs.nga.cn/read.php?tid=9002">打开站内关联话题</a></p>
              """
            : "<p>这是通过站内链接打开的关联话题。</p>"
        let sanitizedFirstPostHTML = NGAParser().sanitizedPostHTML(firstPostHTML)
        let renderedFirstPostHTML: String
        if isPrimaryTopic,
           ProcessInfo.processInfo.arguments.contains("--uitesting-image-thread") {
            let tallImage = """
            <img
                src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxMDAiIGhlaWdodD0iMjQwMCI+PHJlY3Qgd2lkdGg9IjEwMCIgaGVpZ2h0PSIyNDAwIiBmaWxsPSIjY2NjIi8+PC9zdmc+"
                width="100"
                height="2400"
                loading="eager"
                decoding="async"
                alt="滚动性能测试图片"
            >
            """
            renderedFirstPostHTML = sanitizedFirstPostHTML.replacingOccurrences(
                of: "</main>",
                with: "\(tallImage)</main>"
            )
        } else {
            renderedFirstPostHTML = sanitizedFirstPostHTML
        }
        // 走原生渲染的楼层：引用块、正文和一个站内链接，覆盖 PostContentView 的
        // 主要分支（第一层的正文里没有这些，它落在 WKWebView 分支上）。
        let nativeReply = NGAParser().sanitizedPost(
            "[quote]引用内容[/quote]回复成功。<br/>[url=https://bbs.nga.cn/read.php?tid=9002]打开原生关联话题[/url]"
        )
        let postIDOffset = page == 1 ? 0 : Int64((page - 1) * 100)
        let allPosts = [
            Post(
                id: PostID(rawValue: 1 + postIDOffset),
                topicID: topicID,
                floor: 0,
                author: "测试用户",
                authorUID: isPrimaryTopic ? 1001 : 1002,
                authorInfo: isPrimaryTopic
                    ? PostAuthorInfo(
                        levelTitle: "一心净土",
                        reputation: 2030,
                        reputationLevel: 11,
                        userGroup: "Warden",
                        registeredAt: Date(timeIntervalSince1970: 1_487_143_790),
                        prestige: 29.7,
                        medals: [
                            UserMedal(
                                id: 386,
                                name: "流浪地球",
                                imageURL: URL(string: "https://img4.nga.cn/ngabbs/medal/386.gif")
                            )
                        ],
                        honor: "于明日落下，静寂与月光"
                    )
                    : nil,
                postedAt: Date(timeIntervalSince1970: 1_785_000_000),
                html: renderedFirstPostHTML,
                poll: isPrimaryTopic
                    ? TopicPoll(
                        id: topicID,
                        groups: [
                            TopicPoll.Group(
                                id: 0,
                                title: nil,
                                options: [
                                    TopicPoll.Option(id: "1", title: "原生客户端", voteCount: 18),
                                    TopicPoll.Option(id: "2", title: "网页端", voteCount: 7),
                                    TopicPoll.Option(id: "3", title: "都在使用", voteCount: 5)
                                ]
                            )
                        ],
                        maximumSelectionsPerGroup: 1,
                        endsAt: Date(timeIntervalSince1970: 1_893_427_200),
                        hidesResultsUntilVoting: false,
                        hidesResultsUntilEnd: false,
                        participantCount: 30
                    )
                    : nil
            ),
            Post(
                id: PostID(rawValue: 2 + postIDOffset),
                topicID: topicID,
                floor: 1,
                author: "回复用户",
                authorUID: 2001,
                html: nativeReply.html,
                nativeContent: nativeReply.nativeContent,
                ratingScores: isPrimaryTopic ? ["100": 8] : [:]
            )
        ]
        if ProcessInfo.processInfo.arguments.contains("--uitesting-shapes") {
            return ThreadPage(
                topic: topic,
                posts: debugShapePosts(topicID: topicID, idOffset: postIDOffset),
                page: page,
                hasMore: false,
                totalPages: 1
            )
        }
        let visiblePosts = authorUID.map { targetUID in
            allPosts.filter { $0.authorUID == targetUID }
        } ?? allPosts
        let totalPages = authorUID == nil ? 3 : 1
        return ThreadPage(
            topic: topic,
            posts: visiblePosts,
            page: page,
            hasMore: page < totalPages,
            totalPages: totalPages
        )
    }

    private struct DebugShape {
        let name: String
        let raw: String
        var edits: [PostEdit] = []
    }

    /// 段落形状楼层只在 `--uitesting-shapes` 下单独成页。
    ///
    /// 混进默认话题会把它从两层变成十层，滚动类用例的内容高度随之改变 ——
    /// testImageHeavyThreadCanReturnToTop 原本两次上滑就到底了，多出来的楼层
    /// 让它一路滑过首楼，首楼被惰性布局回收，用例就找不到楼主信息了。
    private func debugShapePosts(topicID: TopicID, idOffset: Int64) -> [Post] {
        debugShapes.enumerated().map { index, shape in
            let sanitized = NGAParser().sanitizedPost(shape.raw)
            return Post(
                id: PostID(rawValue: Int64(40 + index) + idOffset),
                topicID: topicID,
                floor: 40 + index,
                author: shape.name,
                authorUID: Int64(4000 + index),
                postedAt: Date(timeIntervalSince1970: 1_786_000_000),
                html: sanitized.html,
                nativeContent: sanitized.nativeContent,
                edits: shape.edits,
                punishment: sanitized.punishment
            )
        }
    }

    private static let quoteHead = "[quote][pid=877855763,47337610,2]Reply[/pid] [b]Post by [uid=62442264]有个账号[/uid] (2026-08-10 21:42):[/b]"

    private var debugShapes: [DebugShape] {
        let head = Self.quoteHead
        return [
            // A：引用块自己的正文。抬头短、被引正文长，首行不是最长行。
            DebugShape(
                name: "A引用块正文",
                raw: "\(head)<br/><br/>为什么解散了一批还得再组织一批？这样解散了还有什么意义？是亚足联还是国际足联拿枪逼着你必须去比赛？[/quote]<br/><br/>短回复。"
            ),
            // B：正文末行最长。
            DebugShape(
                name: "B末行最长",
                raw: "\(head)<br/><br/>被引用的话[/quote]<br/><br/>短的一行。<br/>这一行要写得明显更长一些，长到成为整段里最长的那一行才行。"
            ),
            // C：同一行里混排粗体、颜色和链接。
            DebugShape(
                name: "C混排样式",
                raw: "\(head)<br/><br/>被引用的话[/quote]<br/><br/>[b]加粗开头[/b]普通文字[color=red]红字[/color][url=https://example.com]一个外链[/url]收尾的一行。<br/>第二行写得更长一点，看看混排之后测量还准不准。"
            ),
            // D：正文里带表情。
            DebugShape(
                name: "D带表情",
                raw: "\(head)<br/><br/>被引用的话[/quote]<br/><br/>这一行带表情[s:ac:茶]，后面还要再写一些字把它撑长。<br/>第二行是纯文字，写得比上面那行更长一些用来对比。"
            ),
            // E：正文需要折行，折行之后还有一行。
            DebugShape(
                name: "E长段折行",
                raw: "\(head)<br/><br/>被引用的话[/quote]<br/><br/>这一段本身就很长，长到在窗口里放不下必须自动折行，折行之后下面还跟着一行独立的文字，用来观察点击之后尾巴会不会被裁掉，所以这里要一直写到超过一行为止。<br/>这是折行段落后面的那一行。"
            ),
            // F：嵌套引用。
            DebugShape(
                name: "F嵌套引用",
                raw: "\(head)<br/><br/>[quote][b]Post by 另一个人 (2026-08-09 10:00):[/b]<br/><br/>最里面的被引用内容，写长一些让它折行或者接近折行的边缘。[/quote]<br/><br/>中间层的话[/quote]<br/><br/>最外层的回复。"
            ),
            // G：真实 #48。没有引用块，抬头是一整行加粗 + 回链，正文十来行都在同一段里。
            DebugShape(name: "G真实48层", raw: Self.floor48Raw),
            // H：真实 #49。同样的长正文，这次整个塞进引用块。
            DebugShape(
                name: "H真实49层",
                raw: "[quote][pid=877856100,47336184,3]Reply[/pid] [b]Post by [uid=42545847]Abrahim36[/uid] (2026-08-11 13:33):[/b]<br/><br/>\(Self.floor48Body)[/quote]<br/><br/>短回复。"
            ),
            // I：作者在主题里被禁言，整层默认折叠；顺带带上一条自己改动的记录。
            DebugShape(
                name: "I主题内被处罚",
                raw: "[lessernuke2]被处罚的正文，展开之后才看得见。<br/>第二行写长一点，看看展开后行高对不对得上。[/lessernuke2]",
                edits: [PostEdit(editedAt: Date(timeIntervalSince1970: 1_786_423_085))]
            ),
            // J：因本层发言被处罚；改动记录是版主代改的，而且不止一条。
            DebugShape(
                name: "J本层被处罚",
                raw: "[lessernuke]因为这层的发言被处罚，正文同样默认折叠。[/lessernuke]",
                edits: [
                    PostEdit(
                        editedAt: Date(timeIntervalSince1970: 1_786_423_085),
                        editorUID: 300,
                        editorName: "版主甲"
                    ),
                    PostEdit(
                        editedAt: Date(timeIntervalSince1970: 1_786_430_359),
                        editorUID: 300,
                        editorName: "版主甲"
                    )
                ]
            )
        ]
    }

    private static let floor48Body = [
        "甲A之后就全是职业队了",
        "你连体工队和职业队的区别都分不清楚。怎么好意思说别人不会查的?",
        "我不和你掰扯那些分不分主次的话题，我再重申一点",
        "",
        "国内无论是千万百万年薪，还是3000月薪的足球运动员",
        "他们的薪水99%都是俱乐部发的。钱都是俱乐部通过商业运营赚的，",
        "也就是说，他们是在给单位打工，和你在单位打工是一样的概念。",
        "他们所有人的收入都是单位给的，和你的缴纳的税最多也只有半毛钱关系。",
        "",
        "体彩这几千万，基本上养的都是奥运项目。",
        "足球这种职业比赛，根本不可能靠这些九牛一毛的钱养。"
    ].joined(separator: "<br/>")

    private static let floor48Raw = "[b]Reply to [pid=877856000,47336184,3]Reply[/pid] Post by [uid=42545847]柳灬梦璃[/uid] (2026-08-11 10:12)[/b]<br/>\(floor48Body)"

    func submitReply(topicID: TopicID, submission: ReplySubmission) async throws -> PostID? {
        PostID(rawValue: 3)
    }

    func vote(topicID: TopicID, postID: PostID, direction: PostVoteDirection) async throws -> PostVoteState {
        PostVoteState(
            upvoteCount: direction == .up ? 13 : 12,
            downvoteCount: direction == .down ? 2 : 1,
            userVote: direction
        )
    }

    func submitTopicPollVote(topicID: TopicID, optionIDs: [String]) async throws {}

    func messages(folder: MessageFolder, page: Int) async throws -> MessagePage {
        let isNotification = folder == .notifications
        return MessagePage(folder: folder, messages: [
            ForumMessage(
                id: MessageID(rawValue: isNotification ? 7003 : 7001),
                kind: isNotification ? .mention : .privateMessage,
                sender: "系统测试",
                subject: isNotification ? "测试通知" : "测试消息",
                preview: isNotification ? "这是通知预览" : "这是消息预览",
                sentAt: Date(timeIntervalSince1970: isNotification ? 1_700_000_100 : 1_700_000_000),
                isUnread: true
            )
        ], page: page, hasMore: false)
    }

    func message(id: MessageID) async throws -> ForumMessage {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let html = NGAParser().sanitizedPostHTML("<p>这是消息正文。</p>")
        return ForumMessage(
            id: id,
            kind: .privateMessage,
            sender: "系统测试",
            subject: "测试消息",
            preview: "这是消息预览",
            html: html,
            sentAt: sentAt,
            isUnread: false,
            posts: [
                ForumMessagePost(
                    id: MessageID(rawValue: 7002),
                    author: "系统测试",
                    sentAt: sentAt,
                    html: html
                )
            ]
        )
    }

    func replyMessage(id: MessageID, content: String) async throws {}
    func favorites() async throws -> [Forum] { [forum] }
    func updateFavorite(forumID: ForumID, isFavorite: Bool) async throws {}
    func favoriteTopicFolders() async throws -> [TopicFavoriteFolder] {
        [
            TopicFavoriteFolder(
                id: "1",
                name: "默认收藏夹",
                topicCount: 1,
                isDefault: true
            ),
            TopicFavoriteFolder(
                id: "541",
                name: "未命名的收藏夹#541",
                isPublic: false
            )
        ]
    }
    func favoriteTopics(folderID: String, page: Int) async throws -> ForumPage {
        ForumPage(
            forum: nil,
            topics: [
                Topic(
                    id: TopicID(rawValue: 9001),
                    forumID: forum.id,
                    subject: "话题一：欢迎使用 SNGA",
                    author: "测试用户",
                    replyCount: 2,
                    isFavorite: true
                )
            ],
            page: page,
            hasMore: false
        )
    }
    func updateTopicFavorite(topicID: TopicID, folderID: String, isFavorite: Bool) async throws {}
    func createTopicFavoriteFolder(name: String, isPublic: Bool, isDefault: Bool) async throws -> String? { "542" }
    func updateTopicFavoriteFolder(_ folder: TopicFavoriteFolder) async throws {}
    func deleteTopicFavoriteFolder(folderID: String) async throws {}
    func checkInStatus() async throws -> CheckInStatistics {
        checkInStatusRequestCount += 1
        return CheckInStatistics(
            isCheckedInToday: isCheckedInToday,
            consecutiveDays: isCheckedInToday ? 7 : 6,
            totalDays: isCheckedInToday ? 43 : 42
        )
    }
    func checkIn() async throws -> CheckInResult {
        checkInRequestCount += 1
        isCheckedInToday = true
        return .success(message: "签到成功")
    }

    func debugCheckInRequestCount() -> Int { checkInRequestCount }
    func debugCheckInStatusRequestCount() -> Int { checkInStatusRequestCount }
}
#endif
