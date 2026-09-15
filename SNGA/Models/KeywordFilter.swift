import Foundation
import SwiftUI

/// 命中关键字之后拿这条话题怎么办。
///
/// 三档是三种不同的诉求，不是一个强度滑块：
/// - **高亮**是「我要盯着这个词」—— 讨论串照常在列表里，只是一眼能找到。
/// - **折叠**是「多半不想看，但别替我决定」—— 收成一行，想看点开。
/// - **隐藏**是「别出现在我眼前」—— 不画这一行，只在列表末尾记一笔条数。
///
/// 隐藏那一档留着计数，是因为「悄悄少了几条」和「这个版面本来就这么冷清」在
/// 界面上长得一模一样。过滤是用户自己设的，但他有权知道它此刻正在起作用。
enum KeywordFilterAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case highlight
    case fold
    case hide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highlight: "高亮"
        case .fold: "折叠"
        case .hide: "隐藏"
        }
    }

    var systemImage: String {
        switch self {
        case .highlight: "highlighter"
        case .fold: "rectangle.compress.vertical"
        case .hide: "eye.slash"
        }
    }

    /// 同一条话题被多条规则命中时谁说了算。大的赢。
    ///
    /// 顺序按「用户为这条规则花的力气」排：设了隐藏的人显然比设了高亮的人更
    /// 不想看见它，反过来让高亮把隐藏顶掉，等于让最弱的意图覆盖最强的。
    var precedence: Int {
        switch self {
        case .highlight: 0
        case .fold: 1
        case .hide: 2
        }
    }
}

/// 拿话题的哪一面去比。
///
/// 两档的比法**不一样**，这不是疏忽：
/// - **标题**按子串比。「显卡」该命中「出二手显卡一张」，否则这一档没什么用。
/// - **作者**按整个名字比。屏蔽的是某一个人，不是一类名字 —— 按子串比的话，
///   屏蔽「ab」会连坐「abc」「cab」，被误伤的人还不知道自己怎么消失的。
///   代价是「名字里带 bot 的全屏蔽」做不到，但那件事远比误伤一个人少见。
enum KeywordFilterScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case subject
    case author

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subject: "标题"
        case .author: "作者"
        }
    }

    /// 输入框里那句提示。两档要写的东西不一样：标题是词，作者要写全名。
    var prompt: String {
        switch self {
        case .subject: "关键字，用逗号隔开"
        case .author: "作者全名，用逗号隔开"
        }
    }
}

/// 命中了什么。界面上要把它说出来 —— 「含关键字」和「作者是谁」是两句话，
/// 混成一句，用户就看不出该去改哪一条规则。
struct KeywordFilterMatch: Equatable, Sendable {
    var keyword: String
    var scope: KeywordFilterScope

    var description: String {
        switch scope {
        case .subject: "含关键字「\(keyword)」"
        case .author: "作者「\(keyword)」"
        }
    }
}

/// 一条关键字规则。
///
/// 一条规则里可以并列多个词（`keywords` 用逗号分隔），它们之间是「或」的关系 ——
/// 「显卡,矿卡,4090」是同一件事的三种叫法，分成三条规则就要配三次颜色、改三次档位。
/// 作者那一档同理：一条规则里可以并列几个人。
struct KeywordFilterRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// 用户输入的原文，原样存。拆词是读的时候做的事 ——
    /// 存拆好的数组，用户再打开设置就看不到自己当初写的那一行了。
    var keywords: String
    /// 拿话题的哪一面去比。
    var scope: KeywordFilterScope
    var action: KeywordFilterAction
    /// 只有 `.highlight` 用得上。换档位时不清掉它，改回高亮时颜色还在。
    var colorHex: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        keywords: String = "",
        scope: KeywordFilterScope = .subject,
        action: KeywordFilterAction = .highlight,
        colorHex: String = KeywordFilterSettings.defaultHighlightHex,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.keywords = keywords
        self.scope = scope
        self.action = action
        self.colorHex = colorHex
        self.isEnabled = isEnabled
    }

    /// 2.0.0 存下来的规则里没有 `scope` —— 那时只能按标题过滤。
    ///
    /// 缺了就当标题，而不是让整条规则解不出来。合成的 `Decodable` 遇到缺字段会
    /// 整条抛错，而 `KeywordFilterSettings.decode` 抛错就返回空数组：升级一次，
    /// 用户攒的词全没了。这个自定义构造器只为这一件事存在。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        keywords = try container.decode(String.self, forKey: .keywords)
        action = try container.decode(KeywordFilterAction.self, forKey: .action)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        scope = try container.decodeIfPresent(KeywordFilterScope.self, forKey: .scope) ?? .subject
    }

    /// 拆开之后真正参与匹配的词。
    ///
    /// 只按逗号拆，不按空格：「free vps」「显卡 涨价」这种带空格的词组是常事，
    /// 按空格拆会把它们变成两个宽得多的词，过滤范围比用户写的大一圈。
    /// 半角和全角逗号都认 —— 中文输入法下打出来的多半是全角那个。
    var matchWords: [String] {
        keywords
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 这条规则此刻有没有用。没写词的规则（刚点「添加」那一条）不参与匹配。
    var isActive: Bool { isEnabled && !matchWords.isEmpty }

    /// 这条规则命中了没有。命中哪个词也一并带出来 —— 界面上要说得出是哪条规则
    /// 收走了它，用户才改得了。
    func match(subject: String, author: String) -> KeywordFilterMatch? {
        let haystack = scope == .subject ? subject : author
        guard !haystack.isEmpty else { return nil }
        let hit = matchWords.first { word in
            switch scope {
            case .subject: haystack.keywordFilterContains(word)
            case .author: haystack.keywordFilterEquals(word)
            }
        }
        return hit.map { KeywordFilterMatch(keyword: $0, scope: scope) }
    }
}

/// 一条话题在过滤器下的去向。
enum KeywordFilterVerdict: Equatable, Sendable {
    case show
    /// 命中了什么一并带出来，界面上要把它说出来 —— 光变个底色，用户看不出是
    /// 哪条规则干的，也就无从修改。
    case highlight(colorHex: String, match: KeywordFilterMatch)
    case fold(match: KeywordFilterMatch)
    case hide(match: KeywordFilterMatch)
}

/// 解析好的一整套规则。和字体、主题一样从应用顶上一次注入。
///
/// 不让每一行话题自己去读一遍 `@AppStorage`：一屏几十行，那是几十个
/// UserDefaults 观察者，外加几十次 JSON 解码。
struct ResolvedKeywordFilter: Equatable, Sendable {
    /// 总开关。关掉之后规则原样留着，只是不起作用 —— 想「暂时看看原样」的人
    /// 不必把自己攒的词全删一遍。
    var isEnabled: Bool
    var rules: [KeywordFilterRule]

    static let none = ResolvedKeywordFilter(isEnabled: true, rules: [])

    init(isEnabled: Bool = true, rules: [KeywordFilterRule] = []) {
        self.isEnabled = isEnabled
        self.rules = rules
    }

    /// 此刻会不会改变任何一条话题的样子。为假时调用方可以整段跳过。
    var isActive: Bool {
        isEnabled && rules.contains(where: \.isActive)
    }

    /// 这条话题该怎么显示。
    ///
    /// 命中多条规则时，先比档位（隐藏 > 折叠 > 高亮），同档位里取**排在前面**的
    /// 那一条 —— 颜色只能有一个，取第一条至少是用户在设置里能看见的顺序。
    /// 标题规则和作者规则在这里一视同仁地比，不分先后。
    func verdict(forSubject subject: String, author: String = "") -> KeywordFilterVerdict {
        guard isEnabled else { return .show }
        var winner: (rule: KeywordFilterRule, match: KeywordFilterMatch)?
        for rule in rules where rule.isActive {
            guard let match = rule.match(subject: subject, author: author) else { continue }
            if let current = winner,
               rule.action.precedence <= current.rule.action.precedence {
                continue
            }
            winner = (rule, match)
        }
        guard let winner else { return .show }
        switch winner.rule.action {
        case .highlight:
            return .highlight(colorHex: winner.rule.colorHex, match: winner.match)
        case .fold:
            return .fold(match: winner.match)
        case .hide:
            return .hide(match: winner.match)
        }
    }
}

private extension String {
    /// 标题那一档用的「含有」。
    ///
    /// 明确传 `locale: nil` 而不是走 `localizedStandardContains`：过滤结果不该
    /// 随系统语言变，测试也就能断言得死。
    func keywordFilterContains(_ keyword: String) -> Bool {
        range(of: keyword, options: keywordFilterOptions, range: nil, locale: nil) != nil
    }

    /// 作者那一档用的「就是这个人」。宽松程度和上面一致（大小写、全半角、变音符号），
    /// 只是比的是整个名字，不是其中一段。
    func keywordFilterEquals(_ keyword: String) -> Bool {
        compare(
            keyword,
            options: keywordFilterOptions,
            range: nil,
            locale: nil
        ) == .orderedSame
    }
}

/// 大小写不敏感（VPS / vps）、变音符号不敏感（café / cafe）、全半角不敏感
/// （ＡＰＩ / API —— 中文输入法下打出全角字母是常事，标题党尤其爱用）。
private let keywordFilterOptions: String.CompareOptions = [
    .caseInsensitive, .diacriticInsensitive, .widthInsensitive
]

/// 规则存在哪儿、怎么编解码。
///
/// 存 UserDefaults 而不是 SwiftData：过滤规则是「这台机器上的这个人不想看什么」，
/// 跟账号和站点都没关系 —— 换个账号还得重配一遍关键字是说不通的。而 SwiftData
/// 里那几张表的主键一律以 `accountIDString` 打头，天生是按账号切开的。
enum KeywordFilterSettings {
    static let enabledKey = "browsing.keywordFilter.enabled"
    static let rulesKey = "browsing.keywordFilter.rules"

    /// 一片淡黄，接近纸上荧光笔划过的痕迹；在六套主题下都还认得出是「被标了」。
    static let defaultHighlightHex = "#FFF3B0"

    /// 备选色。挑的是色相拉得开的几支，扫一眼就能分出是哪条规则命中的。
    static let presetHighlightHexes = [
        "#FFF3B0", "#FFD5C2", "#FFC9D6", "#D9D2FF", "#C5E3FF", "#C8EFD4"
    ]

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }

    /// 规则条数的上限。定得住手是因为每条规则都要在每条标题上扫一遍 ——
    /// 一屏 50 条话题 × 40 条规则 × 几个词，已经是几千次子串查找。
    static let maximumRuleCount = 40

    /// 存成一行 JSON。
    ///
    /// 没有给每条规则一个 UserDefaults 键：那样删一条就要自己维护键的回收，
    /// 而一整个数组的读写本来就是原子的。
    static func encode(_ rules: [KeywordFilterRule]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rules),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    /// 解不出来就当没有规则。
    ///
    /// 宁可少过滤也不能把一条错误的规则当成对的用 —— 用户看到的是一个「过滤失灵」
    /// 的列表，而不是一个悄悄按半条规则藏了东西的列表。
    static func decode(_ json: String) -> [KeywordFilterRule] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let rules = try? JSONDecoder().decode([KeywordFilterRule].self, from: data) else {
            return []
        }
        return Array(rules.prefix(maximumRuleCount))
    }
}

extension EnvironmentValues {
    @Entry var sngaKeywordFilter: ResolvedKeywordFilter = .none
}
