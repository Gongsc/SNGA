import Foundation

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

struct NGAEndpoint: Sendable {
    static let baseURL = URL(string: "https://bbs.nga.cn")!

    var path: String
    var queryItems: [URLQueryItem] = []
    var method: HTTPMethod = .get
    var form: [String: String] = [:]
    var referer: URL?
    var isWrite = false
    var userAgentOverride: String?

    var url: URL {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url!
    }

    static func profile(uid: Int64) -> NGAEndpoint {
        NGAEndpoint(path: "/nuke.php", queryItems: [
            .init(name: "__lib", value: "ucp"),
            .init(name: "__act", value: "get"),
            .init(name: "uid", value: String(uid)),
            .init(name: "__output", value: "11")
        ])
    }

    static func userActivities(uid: Int64, kind: UserActivityKind, page: Int) -> NGAEndpoint {
        var items = [
            URLQueryItem(name: "authorid", value: String(uid)),
            URLQueryItem(name: "page", value: String(max(1, page)))
        ]
        if kind == .replies {
            items.insert(URLQueryItem(name: "searchpost", value: "1"), at: 0)
        }
        return NGAEndpoint(
            path: "/thread.php",
            queryItems: items,
            userAgentOverride: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/101.0.4951.64 Safari/537.36"
        )
    }

    static let forums = NGAEndpoint(
        path: "/app_api.php",
        queryItems: [
            .init(name: "__lib", value: "home"),
            .init(name: "__act", value: "category"),
            .init(name: "_v", value: "2")
        ],
        method: .post,
        form: [
            "__output": "11",
            "__inchst": "UTF8"
        ]
    )

    static func topics(forumID: ForumID, page: Int) -> NGAEndpoint {
        NGAEndpoint(path: "/thread.php", queryItems: [
            .init(name: forumID.queryName, value: forumID.description),
            .init(name: "page", value: String(max(1, page))),
            .init(name: "__output", value: "11")
        ])
    }

    static func thread(topicID: TopicID, page: Int) -> NGAEndpoint {
        NGAEndpoint(path: "/read.php", queryItems: [
            .init(name: "tid", value: topicID.description),
            .init(name: "page", value: String(max(1, page))),
            .init(name: "__output", value: "11")
        ], userAgentOverride: "NGA_WP_JW/(;WINDOWS)")
    }

    static func threadHTML(topicID: TopicID, page: Int) -> NGAEndpoint {
        NGAEndpoint(
            path: "/read.php",
            queryItems: [
                .init(name: "tid", value: topicID.description),
                .init(name: "page", value: String(max(1, page)))
            ],
            userAgentOverride: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/101.0.4951.64 Safari/537.36"
        )
    }

    static func topicWebURL(topicID: TopicID) -> URL {
        var components = URLComponents(
            url: baseURL.appending(path: "/read.php"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            .init(name: "tid", value: topicID.description)
        ]
        return components.url!
    }

    static func replyForm(topicID: TopicID, replyTo: PostID?) -> NGAEndpoint {
        var items = [
            URLQueryItem(name: "action", value: "reply"),
            URLQueryItem(name: "tid", value: topicID.description),
            URLQueryItem(name: "lite", value: "xml"),
            URLQueryItem(name: "__inchst", value: "UTF8")
        ]
        if let replyTo {
            items.append(URLQueryItem(name: "pid", value: replyTo.description))
        }
        return NGAEndpoint(
            path: "/post.php",
            queryItems: items,
            method: .post,
            referer: baseURL,
            userAgentOverride: "NGA_WP_JW/(;WINDOWS)"
        )
    }

    static func vote(topicID: TopicID, postID: PostID, direction: PostVoteDirection) -> NGAEndpoint {
        NGAEndpoint(
            path: "/nuke.php",
            queryItems: [
                .init(name: "__lib", value: "topic_recommend"),
                .init(name: "__act", value: "add"),
                .init(name: "raw", value: "3"),
                // 点赞接口默认可能返回网页脚本；显式请求 XML，才能取得
                // 最新赞/踩数量以及当前用户的选择状态。
                .init(name: "lite", value: "xml")
            ],
            method: .post,
            form: [
                "tid": topicID.description,
                "pid": postID.description,
                "value": direction.requestValue
            ],
            isWrite: true,
            userAgentOverride: "NGA_WP_JW/(;WINDOWS)"
        )
    }

    static func messages(folder: MessageFolder, page: Int) -> NGAEndpoint {
        switch folder {
        case .privateMessages:
            let items: [URLQueryItem] = [
                URLQueryItem(name: "__lib", value: "message"),
                URLQueryItem(name: "__act", value: "message"),
                URLQueryItem(name: "act", value: "list"),
                URLQueryItem(name: "page", value: String(max(1, page))),
                URLQueryItem(name: "__output", value: "11")
            ]
            return NGAEndpoint(path: "/nuke.php", queryItems: items, method: .post)
        case .notifications:
            return NGAEndpoint(path: "/nuke.php", queryItems: [
                .init(name: "__lib", value: "noti"),
                .init(name: "__act", value: "get_all"),
                .init(name: "__output", value: "11")
            ], method: .post)
        }
    }

    static func message(id: MessageID) -> NGAEndpoint {
        NGAEndpoint(path: "/nuke.php", queryItems: [
            .init(name: "__lib", value: "message"),
            .init(name: "__act", value: "message"),
            .init(name: "act", value: "read"),
            .init(name: "mid", value: id.description),
            .init(name: "__output", value: "11")
        ], method: .post)
    }

    static func replyMessage(id: MessageID, content: String) -> NGAEndpoint {
        NGAEndpoint(
            path: "/nuke.php",
            queryItems: [
                .init(name: "__lib", value: "message"),
                .init(name: "__act", value: "message"),
                .init(name: "act", value: "reply"),
                .init(name: "__output", value: "11")
            ],
            method: .post,
            form: [
                "mid": id.description,
                "content": content
            ],
            isWrite: true
        )
    }

    static let favorites = NGAEndpoint(
        path: "/app_api.php",
        queryItems: [
            .init(name: "__lib", value: "favorforum"),
            .init(name: "__act", value: "sync")
        ],
        method: .post,
        form: [
            "__output": "11",
            "__inchst": "UTF8"
        ]
    )

    static let legacyFavorites = NGAEndpoint(
        path: "/nuke.php",
        queryItems: [
            .init(name: "__lib", value: "forum_favor2"),
            .init(name: "__act", value: "forum_favor"),
            .init(name: "__output", value: "11")
        ],
        method: .post,
        form: ["action": "get"]
    )

    static func updateFavorite(forumID: ForumID, isFavorite: Bool, legacy: Bool = false) -> NGAEndpoint {
        if legacy {
            return NGAEndpoint(
                path: "/nuke.php",
                queryItems: [
                    .init(name: "__lib", value: "forum_favor2"),
                    .init(name: "__act", value: "forum_favor"),
                    .init(name: "__output", value: "11")
                ],
                method: .post,
                form: [
                    "action": isFavorite ? "add" : "del",
                    "fid": forumID.description
                ],
                isWrite: true
            )
        }
        return NGAEndpoint(
            path: "/app_api.php",
            queryItems: [
                .init(name: "__lib", value: "favorforum"),
                .init(name: "__act", value: isFavorite ? "add" : "del")
            ],
            method: .post,
            form: [
                "__output": "11",
                "__inchst": "UTF8",
                "fid": forumID.description
            ],
            isWrite: true
        )
    }

    static let favoriteTopicFolders = NGAEndpoint(
        path: "/nuke.php",
        queryItems: [
            .init(name: "__lib", value: "topic_favor_v2"),
            .init(name: "__act", value: "list_folder"),
            .init(name: "page", value: "1"),
            .init(name: "__output", value: "8")
        ],
        method: .post,
        form: ["__inchst": "UTF8"],
        userAgentOverride: "NGA_WP_JW/(;WINDOWS)"
    )

    static func favoriteTopics(folderID: String, page: Int) -> NGAEndpoint {
        NGAEndpoint(
            path: "/thread.php",
            queryItems: [
                .init(name: "favor", value: folderID),
                .init(name: "order_by", value: "postdatedesc"),
                .init(name: "page", value: String(max(1, page))),
                .init(name: "__output", value: "11")
            ],
            userAgentOverride: "NGA_WP_JW/(;WINDOWS)"
        )
    }

    static func updateTopicFavorite(
        topicID: TopicID,
        folderID: String,
        isFavorite: Bool
    ) -> NGAEndpoint {
        NGAEndpoint(
            path: "/nuke.php",
            queryItems: [
                .init(name: "__lib", value: "topic_favor_v2"),
                .init(name: "__act", value: isFavorite ? "add" : "del"),
                .init(name: "__output", value: "11")
            ],
            method: .post,
            form: [
                "__inchst": "UTF8",
                "folder": folderID,
                (isFavorite ? "tid" : "tidarray"): topicID.description
            ],
            referer: topicWebURL(topicID: topicID),
            isWrite: true,
            userAgentOverride: "NGA_WP_JW/(;WINDOWS)"
        )
    }

    static func createTopicFavoriteFolder(
        name: String,
        isPublic: Bool,
        isDefault: Bool
    ) -> NGAEndpoint {
        NGAEndpoint(
            path: "/nuke.php",
            queryItems: [
                .init(name: "__lib", value: "topic_favor_v2"),
                .init(name: "__act", value: "new_folder"),
                .init(name: "raw", value: "3"),
                .init(name: "__output", value: "8")
            ],
            method: .post,
            form: [
                "__inchst": "UTF8",
                "name": name,
                "opt": topicFavoriteFolderOption(
                    isPublic: isPublic,
                    isDefault: isDefault
                )
            ],
            referer: baseURL,
            isWrite: true,
            userAgentOverride: "NGA_WP_JW/(;WINDOWS)"
        )
    }

    static func updateTopicFavoriteFolder(_ folder: TopicFavoriteFolder) -> NGAEndpoint {
        NGAEndpoint(
            path: "/nuke.php",
            queryItems: [
                .init(name: "__lib", value: "topic_favor_v2"),
                .init(name: "__act", value: "modify_folder"),
                .init(name: "raw", value: "3"),
                .init(name: "__output", value: "8")
            ],
            method: .post,
            form: [
                "__inchst": "UTF8",
                "folder": folder.id,
                "name": folder.name,
                "opt": topicFavoriteFolderOption(
                    isPublic: folder.isPublic,
                    isDefault: folder.isDefault
                )
            ],
            referer: baseURL,
            isWrite: true,
            userAgentOverride: "NGA_WP_JW/(;WINDOWS)"
        )
    }

    static func deleteTopicFavoriteFolder(folderID: String) -> NGAEndpoint {
        NGAEndpoint(
            path: "/nuke.php",
            queryItems: [
                .init(name: "__lib", value: "topic_favor_v2"),
                .init(name: "__act", value: "del_folder"),
                .init(name: "raw", value: "3"),
                .init(name: "__output", value: "8")
            ],
            method: .post,
            form: [
                "__inchst": "UTF8",
                "folder": folderID
            ],
            referer: baseURL,
            isWrite: true,
            userAgentOverride: "NGA_WP_JW/(;WINDOWS)"
        )
    }

    private static func topicFavoriteFolderOption(
        isPublic: Bool,
        isDefault: Bool
    ) -> String {
        String((isPublic ? 1 : 0) | (isDefault ? 2 : 0))
    }

    static let checkIn = NGAEndpoint(
        path: "/nuke.php",
        queryItems: [
            .init(name: "__lib", value: "check_in"),
            .init(name: "__act", value: "check_in"),
            .init(name: "__output", value: "8"),
            .init(name: "__inchst", value: "UTF8")
        ],
        method: .post,
        referer: baseURL,
        isWrite: true
    )
}
