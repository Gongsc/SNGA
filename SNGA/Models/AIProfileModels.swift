import Foundation
import SwiftData

enum AISettings {
    static let baseURLKey = "ai.baseURL"
    static let modelKey = "ai.model"
    static let instructionKey = "ai.instruction"
    static let historyLimitKey = "ai.historyLimit"

    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultHistoryLimit = 50
    static let allowedHistoryLimit = 1...200
    static let maximumInputBytes = 64 * 1024

    static let defaultInstruction = """
    你是 NGA 用户画像分析助手。请仅依据提供的公开资料和近期发布记录，用简体中文输出：
    1. 一句话概览
    2. 关注领域与兴趣，并给出对应内容依据
    3. 发言与互动风格
    4. 活跃特征
    5. 不确定性与样本局限

    明确区分可观察事实与合理推测，不推断政治倾向、健康状况等敏感属性，不进行诊断、攻击或贬损。
    """

    static var baseURLString: String {
        UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL
    }

    static var model: String {
        UserDefaults.standard.string(forKey: modelKey) ?? ""
    }

    static var instruction: String {
        UserDefaults.standard.string(forKey: instructionKey) ?? defaultInstruction
    }

    static var historyLimit: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: historyLimitKey) != nil else {
            return defaultHistoryLimit
        }
        return normalizedHistoryLimit(defaults.integer(forKey: historyLimitKey))
    }

    static var isConfigured: Bool {
        normalizedBaseURL(from: baseURLString) != nil
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func normalizedHistoryLimit(_ value: Int) -> Int {
        min(max(value, allowedHistoryLimit.lowerBound), allowedHistoryLimit.upperBound)
    }

    static func normalizedBaseURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        // Foundation may expose an IPv6 URLComponents host either with or without
        // its URL brackets depending on the SDK version.
        let host = rawHost == "[::1]" ? "::1" : rawHost
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            return nil
        }

        components.scheme = scheme
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !components.path.isEmpty {
            components.path = "/\(components.path)"
        }
        return components.url
    }

    static func configuration(apiKey: String?) throws -> AIConfiguration {
        guard let baseURL = normalizedBaseURL(from: baseURLString) else {
            throw AIServiceError.invalidBaseURL
        }
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedModel.isEmpty else { throw AIServiceError.missingModel }
        let resolvedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedInstruction.isEmpty else { throw AIServiceError.missingInstruction }
        return AIConfiguration(
            baseURL: baseURL,
            model: resolvedModel,
            apiKey: apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
            instruction: resolvedInstruction
        )
    }
}

struct AIConfiguration: Equatable, Sendable {
    var baseURL: URL
    var model: String
    var apiKey: String?
    var instruction: String

    var chatCompletionsURL: URL {
        baseURL
            .appending(path: "chat")
            .appending(path: "completions")
    }
}

struct AIProfileInput: Codable, Equatable, Sendable {
    struct ProfileSnapshot: Codable, Equatable, Sendable {
        var uid: Int64
        var displayName: String
        var userGroup: String?
        var title: String?
        var honor: String?
        var registeredAt: String?
        var postCount: Int?
        var location: String?
        var signature: String?
        var reputation: Double?
        var fame: Int?
        var money: Int?
        var followerCount: Int?
        var isMasked: Bool
    }

    struct ActivitySnapshot: Codable, Equatable, Sendable {
        var kind: String
        var forumName: String?
        var subject: String
        var excerpt: String?
        var postedAt: String?
    }

    struct Coverage: Codable, Equatable, Sendable {
        var pagesPerKind: Int
        var topicCount: Int
        var replyCount: Int
        var wasTruncated: Bool
    }

    var profile: ProfileSnapshot
    var topics: [ActivitySnapshot]
    var replies: [ActivitySnapshot]
    var coverage: Coverage

    static func make(
        profile: Profile,
        topics: [UserActivity],
        replies: [UserActivity],
        maximumBytes: Int = AISettings.maximumInputBytes
    ) -> AIProfileInput {
        var didTruncate = false

        func shortened(_ value: String?, limit: Int) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard trimmed.count > limit else { return trimmed }
            didTruncate = true
            return String(trimmed.prefix(limit)) + "…"
        }

        let formatter = ISO8601DateFormatter()
        let profileSnapshot = ProfileSnapshot(
            uid: profile.uid,
            displayName: shortened(profile.displayName, limit: 200) ?? "NGA \(profile.uid)",
            userGroup: shortened(profile.userGroup, limit: 200),
            title: shortened(profile.title, limit: 300),
            honor: shortened(profile.honor, limit: 500),
            registeredAt: profile.registeredAt.map(formatter.string(from:)),
            postCount: profile.postCount,
            location: shortened(profile.location, limit: 200),
            signature: shortened(profile.signature, limit: 2_000),
            reputation: profile.reputation,
            fame: profile.fame,
            money: profile.money,
            followerCount: profile.followerCount,
            isMasked: profile.isMasked
        )

        func snapshots(_ activities: [UserActivity], kind: UserActivityKind) -> [ActivitySnapshot] {
            activities
                .sorted { lhs, rhs in
                    (lhs.postedAt ?? .distantPast) > (rhs.postedAt ?? .distantPast)
                }
                .map { activity in
                    ActivitySnapshot(
                        kind: kind.rawValue,
                        forumName: shortened(activity.forumName, limit: 200),
                        subject: shortened(activity.subject, limit: 500) ?? "无标题",
                        excerpt: shortened(activity.excerpt, limit: 1_000),
                        postedAt: activity.postedAt.map(formatter.string(from:))
                    )
                }
        }

        var input = AIProfileInput(
            profile: profileSnapshot,
            topics: snapshots(topics, kind: .topics),
            replies: snapshots(replies, kind: .replies),
            coverage: Coverage(
                pagesPerKind: 2,
                topicCount: topics.count,
                replyCount: replies.count,
                wasTruncated: didTruncate
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        while (try? encoder.encode(input).count) ?? 0 > maximumBytes,
              !input.topics.isEmpty || !input.replies.isEmpty {
            didTruncate = true
            if input.topics.count >= input.replies.count, !input.topics.isEmpty {
                input.topics.removeLast()
            } else if !input.replies.isEmpty {
                input.replies.removeLast()
            }
        }
        input.coverage.topicCount = input.topics.count
        input.coverage.replyCount = input.replies.count
        input.coverage.wasTruncated = didTruncate
        return input
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AIServiceError.invalidResponse
        }
        return string
    }
}

@Model
final class AIProfileSummaryRecord {
    @Attribute(.unique) var id: String
    var uid: Int64
    var displayName: String
    var avatarURLString: String?
    var summary: String
    var model: String
    var generatedAt: Date
    var topicCount: Int
    var replyCount: Int
    var wasTruncated: Bool

    init(
        uid: Int64,
        displayName: String,
        avatarURL: URL?,
        summary: String,
        model: String,
        generatedAt: Date = .now,
        topicCount: Int,
        replyCount: Int,
        wasTruncated: Bool
    ) {
        self.id = String(uid)
        self.uid = uid
        self.displayName = displayName
        self.avatarURLString = avatarURL?.absoluteString
        self.summary = summary
        self.model = model
        self.generatedAt = generatedAt
        self.topicCount = topicCount
        self.replyCount = replyCount
        self.wasTruncated = wasTruncated
    }

    var avatarURL: URL? {
        avatarURLString.flatMap(URL.init(string:))
    }

    func update(
        profile: Profile,
        summary: String,
        model: String,
        generatedAt: Date,
        topicCount: Int,
        replyCount: Int,
        wasTruncated: Bool
    ) {
        displayName = profile.displayName
        avatarURLString = profile.avatarURL?.absoluteString
        self.summary = summary
        self.model = model
        self.generatedAt = generatedAt
        self.topicCount = topicCount
        self.replyCount = replyCount
        self.wasTruncated = wasTruncated
    }
}

enum AIServiceError: LocalizedError, Sendable {
    case invalidBaseURL
    case missingModel
    case missingInstruction
    case invalidResponse
    case emptyResponse
    case reasoningOnly(finishReason: String?)
    case server(status: Int, message: String)
    case keychain(status: Int32)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "AI Base URL 无效；仅支持 HTTPS，或使用 HTTP 的本机地址"
        case .missingModel:
            "请先在设置中填写 AI 模型"
        case .missingInstruction:
            "请先在设置中填写 AI 分析指令"
        case .invalidResponse:
            "AI 接口返回了无法识别的响应"
        case .emptyResponse:
            "AI 接口没有返回画像内容"
        case let .reasoningOnly(finishReason):
            if finishReason == "length" {
                "AI 模型只返回了思考过程，尚未生成画像正文就达到输出长度限制"
            } else {
                "AI 模型只返回了思考过程，没有生成画像正文"
            }
        case let .server(status, message):
            message.isEmpty ? "AI 服务请求失败（HTTP \(status)）" : "AI 服务请求失败：\(message)"
        case let .keychain(status):
            "无法访问系统钥匙串（错误 \(status)）"
        case let .unavailable(message):
            message
        }
    }
}
