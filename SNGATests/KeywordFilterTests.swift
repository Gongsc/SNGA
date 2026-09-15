import XCTest
@testable import SNGA

/// 关键字过滤的四件事：词怎么拆、命中怎么判、作者那一档怎么比、规则怎么存。
///
/// 判定这一层刻意做成了纯函数（`ResolvedKeywordFilter.verdict(forSubject:author:)`），
/// 就是为了能在这里断言死 —— 界面那一侧只负责按结论画，不再自己判一遍。
final class KeywordFilterTests: XCTestCase {

    // MARK: - 词怎么拆

    /// 一条规则里并列多个词，半角和全角逗号都认。中文输入法下打出来的是全角那个，
    /// 不认的话用户写的「显卡，矿卡」会变成一个从不命中的长词。
    func testSplitsKeywordsOnBothCommaForms() {
        let rule = KeywordFilterRule(keywords: "显卡,矿卡，4090")
        XCTAssertEqual(rule.matchWords, ["显卡", "矿卡", "4090"])
    }

    /// 词里的空格留着。「free vps」是一个词组，按空格拆会把它变成两个宽得多的词，
    /// 过滤范围比用户写的大一圈。
    func testKeepsSpacesInsideOneKeyword() {
        let rule = KeywordFilterRule(keywords: " free vps , 显卡 涨价 ")
        XCTAssertEqual(rule.matchWords, ["free vps", "显卡 涨价"])
    }

    /// 多打的逗号不该变成一个空词 —— 空词对任何标题都「命中」，等于整条规则失控。
    func testDropsEmptyKeywords() {
        let rule = KeywordFilterRule(keywords: "带货,,  ,，广告")
        XCTAssertEqual(rule.matchWords, ["带货", "广告"])
    }

    /// 一条词都没写的规则不参与匹配。点了「添加规则」还没打字的那一条就是这样。
    func testRuleWithoutKeywordsIsInactive() {
        XCTAssertFalse(KeywordFilterRule(keywords: "   ").isActive)
        XCTAssertFalse(KeywordFilterRule(keywords: "带货", isEnabled: false).isActive)
        XCTAssertTrue(KeywordFilterRule(keywords: "带货").isActive)
    }

    // MARK: - 命中怎么判

    /// 没有规则时什么都不该变。默认装好的应用就是这个状态。
    func testEmptyFilterShowsEverything() {
        let filter = ResolvedKeywordFilter.none
        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(filter.verdict(forSubject: "随便一条标题"), .show)
    }

    func testMatchesSubstringOfSubject() {
        let filter = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "带货", action: .hide)
        ])
        XCTAssertEqual(filter.verdict(forSubject: "【带货】这个真的好用"), .hide(match: .subject("带货")))
        XCTAssertEqual(filter.verdict(forSubject: "今天天气不错"), .show)
    }

    /// 大小写、全半角、变音符号都不敏感。少了任何一条，用户就得为同一个词多写几条规则。
    func testMatchingIgnoresCaseWidthAndDiacritics() {
        let filter = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "vps,cafe", action: .hide)
        ])
        XCTAssertEqual(filter.verdict(forSubject: "便宜 VPS 推荐"), .hide(match: .subject("vps")))
        XCTAssertEqual(filter.verdict(forSubject: "便宜 ＶＰＳ 推荐"), .hide(match: .subject("vps")))
        XCTAssertEqual(filter.verdict(forSubject: "Café 里写代码"), .hide(match: .subject("cafe")))
    }

    /// 档位有高下：设了隐藏的人显然比设了高亮的人更不想看见它。
    /// 规则的先后不该翻转这个结论 —— 两个顺序都测一遍。
    func testStrongerActionWinsRegardlessOfRuleOrder() {
        let highlight = KeywordFilterRule(keywords: "显卡", action: .highlight)
        let fold = KeywordFilterRule(keywords: "二手", action: .fold)
        let hide = KeywordFilterRule(keywords: "代购", action: .hide)
        let subject = "二手显卡代购"

        XCTAssertEqual(
            ResolvedKeywordFilter(rules: [highlight, fold, hide]).verdict(forSubject: subject),
            .hide(match: .subject("代购"))
        )
        XCTAssertEqual(
            ResolvedKeywordFilter(rules: [hide, fold, highlight]).verdict(forSubject: subject),
            .hide(match: .subject("代购"))
        )
        XCTAssertEqual(
            ResolvedKeywordFilter(rules: [highlight, fold]).verdict(forSubject: subject),
            .fold(match: .subject("二手"))
        )
    }

    /// 同一档里以排在前面的那条为准。颜色只能有一个，取第一条至少是用户在设置里
    /// 看得见的顺序。
    func testFirstRuleWinsWithinTheSameAction() {
        let filter = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "显卡", action: .highlight, colorHex: "#FFF3B0"),
            KeywordFilterRule(keywords: "二手", action: .highlight, colorHex: "#C5E3FF")
        ])
        XCTAssertEqual(
            filter.verdict(forSubject: "二手显卡出"),
            .highlight(colorHex: "#FFF3B0", match: .subject("显卡"))
        )
    }

    /// 停用的规则不参与，但仍旧留在列表里。
    func testDisabledRuleDoesNotMatch() {
        let filter = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "带货", action: .hide, isEnabled: false)
        ])
        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(filter.verdict(forSubject: "【带货】这个真的好用"), .show)
        XCTAssertEqual(filter.rules.count, 1)
    }

    /// 总开关关掉之后一条都不生效，规则原样留着 ——
    /// 想「暂时看看原样」的人不必把自己攒的词全删一遍。
    func testMasterSwitchSuspendsEveryRule() {
        let rules = [KeywordFilterRule(keywords: "带货", action: .hide)]
        let filter = ResolvedKeywordFilter(isEnabled: false, rules: rules)
        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(filter.verdict(forSubject: "【带货】这个真的好用"), .show)
        XCTAssertEqual(filter.rules, rules)
    }

    /// 空标题不该被任何规则命中。站点偶尔给出没有标题的行（解析边角），
    /// 那一行该照常显示，而不是被当成「命中了每一条」。
    func testEmptySubjectIsNeverFiltered() {
        let filter = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "带货", action: .hide)
        ])
        XCTAssertEqual(filter.verdict(forSubject: ""), .show)
    }

    // MARK: - 作者那一档

    /// 屏蔽某个人：作者名整个对上才算。
    func testAuthorRuleMatchesTheWholeName() {
        let filter = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "某位用户", scope: .author, action: .hide)
        ])
        XCTAssertEqual(
            filter.verdict(forSubject: "随便一条标题", author: "某位用户"),
            .hide(match: .author("某位用户"))
        )
        XCTAssertEqual(filter.verdict(forSubject: "随便一条标题", author: "另一位用户"), .show)
    }

    /// 作者**不**按子串比。屏蔽「ab」不该连坐「abc」——
    /// 被误伤的人不会知道自己在谁的列表里消失了。
    func testAuthorRuleDoesNotMatchBySubstring() {
        let filter = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "ab", scope: .author, action: .hide)
        ])
        XCTAssertEqual(filter.verdict(forSubject: "标题", author: "ab"), .hide(match: .author("ab")))
        XCTAssertEqual(filter.verdict(forSubject: "标题", author: "abc"), .show)
        XCTAssertEqual(filter.verdict(forSubject: "标题", author: "cab"), .show)
    }

    /// 名字的宽松程度和标题一致：大小写、全半角、变音符号都不敏感。
    /// 站点各处对同一个名字的大小写并不总是一致。
    func testAuthorRuleIgnoresCaseWidthAndDiacritics() {
        let filter = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "Livid", scope: .author, action: .hide)
        ])
        XCTAssertEqual(filter.verdict(forSubject: "标题", author: "livid"), .hide(match: .author("Livid")))
        XCTAssertEqual(filter.verdict(forSubject: "标题", author: "ＬＩＶＩＤ"), .hide(match: .author("Livid")))
    }

    /// 一条作者规则里可以并列几个人。
    func testOneAuthorRuleCanListSeveralPeople() {
        let filter = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "甲,乙，丙", scope: .author, action: .fold)
        ])
        XCTAssertEqual(filter.verdict(forSubject: "标题", author: "乙"), .fold(match: .author("乙")))
        XCTAssertEqual(filter.verdict(forSubject: "标题", author: "丁"), .show)
    }

    /// 两档各比各的：标题规则不该因为作者叫这个名字而命中，反过来也一样。
    /// 这一条挡的是「把两边拼成一个字符串去搜」那种写法。
    func testTheTwoScopesDoNotLeakIntoEachOther() {
        let subjectRule = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "带货", action: .hide)
        ])
        XCTAssertEqual(subjectRule.verdict(forSubject: "今天天气不错", author: "带货"), .show)

        let authorRule = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "带货", scope: .author, action: .hide)
        ])
        XCTAssertEqual(authorRule.verdict(forSubject: "【带货】这个真的好用", author: "路人"), .show)
    }

    /// 作者为空的话题（站点没给出作者）不该被任何作者规则命中。
    func testAnEmptyAuthorMatchesNoAuthorRule() {
        let filter = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "某位用户", scope: .author, action: .hide)
        ])
        XCTAssertEqual(filter.verdict(forSubject: "标题", author: ""), .show)
    }

    /// 标题为空、作者命中时照样算数。老的实现在标题为空时直接短路返回 `.show`，
    /// 加了作者档之后那条短路就是个漏判。
    func testAnEmptySubjectStillLetsAuthorRulesRun() {
        let filter = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "某位用户", scope: .author, action: .hide)
        ])
        XCTAssertEqual(filter.verdict(forSubject: "", author: "某位用户"), .hide(match: .author("某位用户")))
    }

    // MARK: - 规则怎么存

    func testRulesSurviveAnEncodeDecodeRoundTrip() {
        let rules = [
            KeywordFilterRule(keywords: "显卡,矿卡", action: .highlight, colorHex: "#C5E3FF"),
            KeywordFilterRule(keywords: "某人", scope: .author, action: .fold),
            KeywordFilterRule(keywords: "带货", action: .hide, isEnabled: false)
        ]
        XCTAssertEqual(KeywordFilterSettings.decode(KeywordFilterSettings.encode(rules)), rules)
    }

    /// 2.0.0 存下来的规则里没有 `scope` —— 那个版本只能按标题过滤。
    ///
    /// 缺了这一项要当成「按标题」，而不是让整条规则解不出来：`decode` 解不出来
    /// 就返回空数组，那意味着升级一次，用户攒的词全没了。这条用例对着一段
    /// 真正的 2.0.0 格式跑。
    func testRulesSavedBeforeTheAuthorScopeStillLoadAsSubjectRules() throws {
        let legacyJSON = """
        [{"action":"hide","colorHex":"#FFF3B0","id":"E5C9D9E4-6C4B-4E2E-9E3F-3F2A1B0C9D8E",        "isEnabled":true,"keywords":"带货,广告"}]
        """
        let rules = KeywordFilterSettings.decode(legacyJSON)
        XCTAssertEqual(rules.count, 1)
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.scope, .subject)
        XCTAssertEqual(rule.keywords, "带货,广告")
        XCTAssertEqual(rule.action, .hide)
        XCTAssertEqual(
            ResolvedKeywordFilter(rules: rules).verdict(forSubject: "【带货】这个真的好用"),
            .hide(match: .subject("带货"))
        )
    }

    /// 存的是一行 JSON，解不出来就当没有规则。
    ///
    /// 宁可少过滤也不能按半条规则藏东西：前者用户一眼看得出「过滤失灵了」，
    /// 后者看上去和站点没发帖一模一样。
    func testUnreadableStorageFallsBackToNoRules() {
        XCTAssertEqual(KeywordFilterSettings.decode(""), [])
        XCTAssertEqual(KeywordFilterSettings.decode("{不是 JSON"), [])
        XCTAssertEqual(KeywordFilterSettings.decode("[{\"keywords\":\"带货\"}]"), [])
    }

    /// 条数有上限：每条规则都要在每条标题上扫一遍，一屏五十条话题乘下去不是小数。
    /// 存量库里超出的部分读的时候截掉，而不是让它一直长。
    func testDecodeTruncatesBeyondTheRuleLimit() {
        let tooMany = (0..<(KeywordFilterSettings.maximumRuleCount + 5)).map { index in
            KeywordFilterRule(keywords: "词\(index)")
        }
        let decoded = KeywordFilterSettings.decode(KeywordFilterSettings.encode(tooMany))
        XCTAssertEqual(decoded.count, KeywordFilterSettings.maximumRuleCount)
        XCTAssertEqual(decoded.first, tooMany.first)
    }

    /// 备选色里不能有重样的：新规则按条数轮着取色，重了就会有两条规则同色，
    /// 高亮也就说不出是被哪一条标的。
    func testPresetHighlightColorsAreDistinct() {
        let hexes = KeywordFilterSettings.presetHighlightHexes
        XCTAssertEqual(Set(hexes).count, hexes.count)
        XCTAssertTrue(hexes.contains(KeywordFilterSettings.defaultHighlightHex))
        for hex in hexes {
            XCTAssertNotNil(ThemeRGB(hex: hex), "备选色 \(hex) 不是一个认得出的颜色")
        }
    }
}

private extension KeywordFilterMatch {
    static func subject(_ keyword: String) -> KeywordFilterMatch {
        KeywordFilterMatch(keyword: keyword, scope: .subject)
    }

    static func author(_ keyword: String) -> KeywordFilterMatch {
        KeywordFilterMatch(keyword: keyword, scope: .author)
    }
}
