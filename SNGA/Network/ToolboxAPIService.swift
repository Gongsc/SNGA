import Foundation

enum ToolboxInstanceChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case primary
    case officialBackup
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动选择（推荐）"
        case .primary: "主实例"
        case .officialBackup: "官方备用实例"
        case .custom: "自定义实例"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic: "依次尝试官方主实例与备用实例"
        case .primary: ToolboxInstanceSettings.primaryBaseURL.absoluteString
        case .officialBackup: ToolboxInstanceSettings.officialBackupBaseURL.absoluteString
        case .custom: "使用自行填写的 60s API 基础地址"
        }
    }
}

enum ToolboxInstanceSettings {
    static let selectionKey = "snga.toolbox.instance.selection"
    static let customBaseURLKey = "snga.toolbox.instance.customBaseURL"
    static let primaryBaseURL = URL(string: "https://60s.viki.moe")!
    static let officialBackupBaseURL = URL(string: "https://60s.b23.run")!
    static let documentationURL = URL(string: "https://docs.60s-api.viki.moe/7306811m0")!

    static var requestBaseURLs: [URL] {
        configuredBaseURLs(
            selectionRawValue: UserDefaults.standard.string(forKey: selectionKey),
            customBaseURLString: UserDefaults.standard.string(forKey: customBaseURLKey) ?? ""
        )
    }

    static func configuredBaseURLs(
        selectionRawValue: String?,
        customBaseURLString: String
    ) -> [URL] {
        let choice = ToolboxInstanceChoice(rawValue: selectionRawValue ?? "")
            ?? .automatic
        let officialURLs = [primaryBaseURL, officialBackupBaseURL]
        let orderedURLs: [URL]

        switch choice {
        case .automatic:
            orderedURLs = officialURLs
        case .primary:
            orderedURLs = [primaryBaseURL]
        case .officialBackup:
            orderedURLs = [officialBackupBaseURL]
        case .custom:
            if let customURL = normalizedBaseURL(from: customBaseURLString) {
                orderedURLs = [customURL]
            } else {
                orderedURLs = []
            }
        }

        var seen = Set<String>()
        return orderedURLs.filter { seen.insert($0.absoluteString).inserted }
    }

    static func normalizedBaseURL(from rawValue: String) -> URL? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > "https://".count, value.hasSuffix("/") {
            value.removeLast()
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        return url
    }
}

enum ToolboxAPIError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case server(Int)
    case service(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "小工具接口返回了无法识别的数据"
        case let .server(status):
            "小工具服务暂时不可用（HTTP \(status)）"
        case let .service(message):
            message.isEmpty ? "小工具服务暂时不可用" : message
        }
    }
}

struct ToolboxAPIService: Sendable {
    private let transport: any HTTPTransport
    private let baseURLs: [URL]?

    init(
        transport: any HTTPTransport = URLSessionTransport(),
        baseURLs: [URL]? = nil
    ) {
        self.transport = transport
        self.baseURLs = baseURLs
    }

    func load(_ feed: ToolboxFeed) async throws -> ToolboxContent {
        var lastError: Error = ToolboxAPIError.invalidResponse

        for baseURL in baseURLs ?? ToolboxInstanceSettings.requestBaseURLs {
            do {
                let endpoint = feed.endpointPath.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                )
                let url = baseURL.appending(path: endpoint)
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 25
                request.setValue("SNGA/1.0 (macOS; native client)", forHTTPHeaderField: "User-Agent")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

                let (data, response) = try await transport.data(for: request)
                guard (200..<300).contains(response.statusCode) else {
                    throw ToolboxAPIError.server(response.statusCode)
                }
                return try parse(feed, from: data)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func parse(_ feed: ToolboxFeed, from data: Data) throws -> ToolboxContent {
        switch feed {
        case .worldBriefing:
            .worldBriefing(try ToolboxAPIParser.worldBriefing(from: data))
        case .aiNews:
            .articles(try ToolboxAPIParser.aiNews(from: data))
        case .itNews:
            .articles(try ToolboxAPIParser.itNews(from: data))
        case .douyinHot:
            .articles(try ToolboxAPIParser.douyinHot(from: data))
        case .rednoteHot:
            .articles(try ToolboxAPIParser.rednoteHot(from: data))
        case .bilibiliHot:
            .articles(try ToolboxAPIParser.bilibiliHot(from: data))
        case .weiboHot:
            .articles(try ToolboxAPIParser.weiboHot(from: data))
        case .zhihuHot:
            .articles(try ToolboxAPIParser.zhihuHot(from: data))
        }
    }
}

enum ToolboxAPIParser {
    static func worldBriefing(from data: Data) throws -> WorldBriefing {
        let envelope: APIEnvelope<WorldBriefingPayload> = try decode(data)
        try validate(envelope.code, message: envelope.message)
        return WorldBriefing(
            date: envelope.data.date,
            dayOfWeek: nonempty(envelope.data.dayOfWeek),
            lunarDate: nonempty(envelope.data.lunarDate),
            news: envelope.data.news.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            tip: nonempty(envelope.data.tip),
            imageURL: httpURL(envelope.data.image),
            coverURL: httpURL(envelope.data.cover),
            sourceURL: httpURL(envelope.data.link),
            updatedAt: date(milliseconds: envelope.data.updatedAt)
        )
    }

    static func aiNews(from data: Data) throws -> [ToolboxArticle] {
        let envelope: APIEnvelope<AINewsPayload> = try decode(data)
        try validate(envelope.code, message: envelope.message)
        return envelope.data.news.compactMap { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ToolboxArticle(
                title: title,
                summary: item.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                source: nonempty(item.source),
                publishedText: nonempty(item.date ?? envelope.data.date),
                link: httpURL(item.link)
            )
        }
    }

    static func itNews(from data: Data) throws -> [ToolboxArticle] {
        let envelope: APIEnvelope<[ITNewsPayload]> = try decode(data)
        try validate(envelope.code, message: envelope.message)
        return envelope.data.compactMap { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ToolboxArticle(
                title: title,
                summary: item.description.trimmingCharacters(in: .whitespacesAndNewlines),
                source: "IT之家",
                publishedText: nonempty(item.created),
                publishedAt: date(milliseconds: item.createdAt),
                link: httpURL(item.link)
            )
        }
    }

    static func douyinHot(from data: Data) throws -> [ToolboxArticle] {
        let envelope: APIEnvelope<[DouyinHotPayload]> = try decode(data)
        try validate(envelope.code, message: envelope.message)
        return envelope.data.enumerated().compactMap { index, item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ToolboxArticle(
                rank: index + 1,
                title: title,
                summary: "",
                source: "抖音",
                publishedText: hotValueDescription(item.hotValue),
                publishedAt: date(milliseconds: item.activeTimeAt),
                link: httpURL(item.link)
            )
        }
    }

    static func rednoteHot(from data: Data) throws -> [ToolboxArticle] {
        let envelope: APIEnvelope<[RednoteHotPayload]> = try decode(data)
        try validate(envelope.code, message: envelope.message)
        return envelope.data.enumerated().compactMap { index, item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let metadata = [
                nonempty(item.score).map { "热度 \($0)" },
                nonempty(item.wordType)
            ]
                .compactMap { $0 }
                .joined(separator: " · ")
            return ToolboxArticle(
                rank: item.rank ?? index + 1,
                title: title,
                summary: "",
                source: "小红书",
                publishedText: nonempty(metadata),
                link: httpURL(item.link)
            )
        }
    }

    static func bilibiliHot(from data: Data) throws -> [ToolboxArticle] {
        let envelope: APIEnvelope<[BilibiliHotPayload]> = try decode(data)
        try validate(envelope.code, message: envelope.message)
        return envelope.data.enumerated().compactMap { index, item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ToolboxArticle(
                rank: index + 1,
                title: title,
                summary: "",
                source: "哔哩哔哩",
                link: httpURL(item.link)
            )
        }
    }

    static func weiboHot(from data: Data) throws -> [ToolboxArticle] {
        let envelope: APIEnvelope<[WeiboHotPayload]> = try decode(data)
        try validate(envelope.code, message: envelope.message)
        return envelope.data.enumerated().compactMap { index, item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ToolboxArticle(
                rank: index + 1,
                title: title,
                summary: "",
                source: "微博",
                publishedText: hotValueDescription(item.hotValue),
                link: httpURL(item.link)
            )
        }
    }

    static func zhihuHot(from data: Data) throws -> [ToolboxArticle] {
        let envelope: APIEnvelope<[ZhihuHotPayload]> = try decode(data)
        try validate(envelope.code, message: envelope.message)
        return envelope.data.enumerated().compactMap { index, item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ToolboxArticle(
                rank: index + 1,
                title: title,
                summary: item.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                source: "知乎",
                publishedText: nonempty(item.hotValueDescription) ?? nonempty(item.created),
                publishedAt: date(milliseconds: item.createdAt),
                link: httpURL(item.link)
            )
        }
    }

    private static func decode<Value: Decodable>(_ data: Data) throws -> APIEnvelope<Value> {
        do {
            return try JSONDecoder().decode(APIEnvelope<Value>.self, from: data)
        } catch {
            throw ToolboxAPIError.invalidResponse
        }
    }

    private static func validate(_ code: Int, message: String) throws {
        guard code == 200 else {
            throw ToolboxAPIError.service(message)
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func httpURL(_ value: String?) -> URL? {
        guard let value = nonempty(value),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private static func date(milliseconds: Double?) -> Date? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private static func hotValueDescription(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        if value >= 100_000_000 {
            return String(format: "热度 %.1f 亿", value / 100_000_000)
        }
        if value >= 10_000 {
            return String(format: "热度 %.1f 万", value / 10_000)
        }
        return "热度 \(Int(value))"
    }
}

private extension ToolboxFeed {
    var endpointPath: String {
        switch self {
        case .worldBriefing: "/v2/60s"
        case .aiNews: "/v2/ai-news"
        case .itNews: "/v2/it-news"
        case .douyinHot: "/v2/douyin"
        case .rednoteHot: "/v2/rednote"
        case .bilibiliHot: "/v2/bili"
        case .weiboHot: "/v2/weibo"
        case .zhihuHot: "/v2/zhihu"
        }
    }
}

private struct APIEnvelope<Value: Decodable>: Decodable {
    var code: Int
    var message: String
    var data: Value
}

private struct WorldBriefingPayload: Decodable {
    var date: String
    var news: [String]
    var cover: String?
    var tip: String?
    var image: String?
    var link: String?
    var dayOfWeek: String?
    var lunarDate: String?
    var updatedAt: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case news
        case cover
        case tip
        case image
        case link
        case dayOfWeek = "day_of_week"
        case lunarDate = "lunar_date"
        case updatedAt = "updated_at"
    }
}

private struct AINewsPayload: Decodable {
    var date: String?
    var news: [AINewsItem]
}

private struct AINewsItem: Decodable {
    var title: String
    var detail: String
    var link: String?
    var source: String?
    var date: String?
}

private struct ITNewsPayload: Decodable {
    var title: String
    var description: String
    var link: String?
    var created: String?
    var createdAt: Double?

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case link
        case created
        case createdAt = "created_at"
    }
}

private struct DouyinHotPayload: Decodable {
    var title: String
    var hotValue: Double?
    var link: String?
    var activeTimeAt: Double?

    enum CodingKeys: String, CodingKey {
        case title
        case link
        case hotValue = "hot_value"
        case activeTimeAt = "active_time_at"
    }
}

private struct RednoteHotPayload: Decodable {
    var rank: Int?
    var title: String
    var score: String?
    var wordType: String?
    var link: String?

    enum CodingKeys: String, CodingKey {
        case rank
        case title
        case score
        case link
        case wordType = "word_type"
    }
}

private struct BilibiliHotPayload: Decodable {
    var title: String
    var link: String?
}

private struct WeiboHotPayload: Decodable {
    var title: String
    var hotValue: Double?
    var link: String?

    enum CodingKeys: String, CodingKey {
        case title
        case link
        case hotValue = "hot_value"
    }
}

private struct ZhihuHotPayload: Decodable {
    var title: String
    var detail: String
    var hotValueDescription: String?
    var createdAt: Double?
    var created: String?
    var link: String?

    enum CodingKeys: String, CodingKey {
        case title
        case detail
        case created
        case link
        case hotValueDescription = "hot_value_desc"
        case createdAt = "created_at"
    }
}
