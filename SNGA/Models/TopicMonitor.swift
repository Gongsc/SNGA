import Foundation

/// 新帖监控：订阅里出现符合规则的标题时提醒一声。
///
/// 这些类型不放 `DomainModels.swift` —— 那份文件描述的是论坛领域，而监控读的是
/// 一份**匿名**订阅，不认账号、不认登录态，和小工具那一侧是一路的。

/// 一条监控规则。
///
/// 两种写法：裸的一行按**忽略大小写**处理（多数人写的是「vmiss」这样的关键词，
/// 为大小写操心没有意义），`/表达式/标志` 则原样照办。
struct TopicMonitorRule: Identifiable, @unchecked Sendable {
    /// 用户写下的那一行，原样留着 —— 报错和着色都要指回它。
    let source: String
    /// 第几条。界面按它分色，让人一眼看出是哪条规则命中的。
    let index: Int
    /// `NSRegularExpression` 是不可变且线程安全的（Apple 的文档明写着），所以
    /// 这个类型标 `@unchecked Sendable` 是成立的，不是在绕过检查。
    private let expression: NSRegularExpression

    var id: String { "\(index):\(source)" }

    fileprivate init(source: String, index: Int, expression: NSRegularExpression) {
        self.source = source
        self.index = index
        self.expression = expression
    }

    func matches(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }
}

enum TopicMonitorRules {
    struct Compiled: Sendable {
        var rules: [TopicMonitorRule]
        /// 编译不过的那几行，原样返回。
        ///
        /// **不是静默丢掉。** 一条写坏的正则和一条永远匹配不上的正则，在界面上
        /// 长得一模一样 —— 用户会以为「就是没有新帖」，而实际上这条规则从一开始
        /// 就没生效。
        var invalidLines: [String]
    }

    /// 每行一条，空行跳过。
    static func compile(_ text: String) -> Compiled {
        var rules: [TopicMonitorRule] = []
        var invalid: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let source = line.trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty else { continue }
            guard let expression = expression(for: source) else {
                invalid.append(source)
                continue
            }
            rules.append(
                TopicMonitorRule(source: source, index: rules.count, expression: expression)
            )
        }
        return Compiled(rules: rules, invalidLines: invalid)
    }

    private static func expression(for source: String) -> NSRegularExpression? {
        var pattern = source
        var options: NSRegularExpression.Options = [.caseInsensitive]
        // `/表达式/标志`：末尾那个斜杠是分隔符，不是表达式的一部分，所以从后往前找。
        // 「/」开头但找不到第二个斜杠的，当成普通表达式处理而不是报错 —— 用户写的
        // 可能就是一条以斜杠开头的关键词。
        if source.hasPrefix("/"),
           let closing = source.lastIndex(of: "/"),
           closing > source.startIndex {
            pattern = String(source[source.index(after: source.startIndex)..<closing])
            let flags = source[source.index(after: closing)...]
            options = []
            for flag in flags {
                switch flag {
                case "i": options.insert(.caseInsensitive)
                case "m": options.insert(.anchorsMatchLines)
                case "s": options.insert(.dotMatchesLineSeparators)
                // 认不得的标志按写坏了处理。悄悄忽略它，用户会以为自己写的生效了。
                default: return nil
                }
            }
        }
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }
}

/// 订阅里的一条。
struct TopicMonitorFeedItem: Identifiable, Hashable, Sendable {
    /// 话题编号。订阅的 `guid` 直接就是它。
    let id: Int64
    var title: String
    var category: String?
    var author: String?
    var publishedAt: Date?
    var link: URL?
}

/// 一条被收录的结果。
struct TopicMonitorHit: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    var title: String
    var category: String?
    var author: String?
    var publishedAt: Date?
    var link: URL?
    /// 是第几条规则命中的。界面按它分色。
    var ruleIndex: Int
    /// 命中的那条规则原文，好让人知道为什么它出现在这儿。
    var ruleSource: String
    var foundAt: Date
    var isUnread: Bool = true
}

struct TopicMonitorCheck: Sendable {
    /// 这一轮新收录的。首次检查一律为空 —— 见 `TopicMonitorPolicy.check`。
    var newHits: [TopicMonitorHit]
    /// 新的水位线。
    var watermark: Int64
    /// 这一轮看了几条、其中几条命中。
    var examined: Int
    var matched: Int
    /// 这一轮是不是「只是记个位置」。
    var isFirstSnapshot: Bool
}

enum TopicMonitorPolicy {
    /// 结果最多留这么多条。
    static let maximumHitCount = 200

    /// 拿一轮订阅结果和规则算出「有什么新的」。
    ///
    /// **首次检查只记位置，不提醒。** 订阅当前返回的那二十条里多半有几条能命中，
    /// 但它们不是「新出现的」，只是「你刚开始看」。第一次就弹二十条通知，用户
    /// 学到的唯一一件事是把提醒关掉。
    ///
    /// **水位线只进不退。** 请求失败根本走不到这里；而返回了旧数据（订阅缓存、
    /// 上游回滚）时，把水位线往回拨会让已经提醒过的帖子再提醒一遍。
    static func check(
        items: [TopicMonitorFeedItem],
        rules: [TopicMonitorRule],
        watermark: Int64?,
        now: Date = Date()
    ) -> TopicMonitorCheck {
        let highest = items.map(\.id).max()
        guard let watermark else {
            return TopicMonitorCheck(
                newHits: [],
                watermark: highest ?? 0,
                examined: items.count,
                matched: items.filter { item in rules.contains { $0.matches(item.title) } }.count,
                isFirstSnapshot: true
            )
        }

        let fresh = items.filter { $0.id > watermark }
        var hits: [TopicMonitorHit] = []
        for item in fresh.sorted(by: { $0.id > $1.id }) {
            guard let rule = rules.first(where: { $0.matches(item.title) }) else { continue }
            hits.append(
                TopicMonitorHit(
                    id: item.id,
                    title: item.title,
                    category: item.category,
                    author: item.author,
                    publishedAt: item.publishedAt,
                    link: item.link,
                    ruleIndex: rule.index,
                    ruleSource: rule.source,
                    foundAt: now
                )
            )
        }
        return TopicMonitorCheck(
            newHits: hits,
            watermark: max(watermark, highest ?? watermark),
            examined: fresh.count,
            matched: hits.count,
            isFirstSnapshot: false
        )
    }

    /// 把新结果并进已有的那一份：新的在前，按编号去重，最多留 200 条。
    static func merging(
        _ existing: [TopicMonitorHit],
        with newHits: [TopicMonitorHit]
    ) -> [TopicMonitorHit] {
        var seen = Set<Int64>()
        return (newHits + existing)
            .filter { seen.insert($0.id).inserted }
            .prefix(maximumHitCount)
            .map { $0 }
    }
}
