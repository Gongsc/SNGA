import XCTest
@testable import SNGA

/// 关键字过滤的三件事：词怎么拆、命中怎么判、规则怎么存。
///
/// 判定这一层刻意做成了纯函数（`ResolvedKeywordFilter.verdict(forSubject:)`），
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
        XCTAssertEqual(filter.verdict(forSubject: "【带货】这个真的好用"), .hide(keyword: "带货"))
        XCTAssertEqual(filter.verdict(forSubject: "今天天气不错"), .show)
    }

    /// 大小写、全半角、变音符号都不敏感。少了任何一条，用户就得为同一个词多写几条规则。
    func testMatchingIgnoresCaseWidthAndDiacritics() {
        let filter = ResolvedKeywordFilter(rules: [
            KeywordFilterRule(keywords: "vps,cafe", action: .hide)
        ])
        XCTAssertEqual(filter.verdict(forSubject: "便宜 VPS 推荐"), .hide(keyword: "vps"))
        XCTAssertEqual(filter.verdict(forSubject: "便宜 ＶＰＳ 推荐"), .hide(keyword: "vps"))
        XCTAssertEqual(filter.verdict(forSubject: "Café 里写代码"), .hide(keyword: "cafe"))
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
            .hide(keyword: "代购")
        )
        XCTAssertEqual(
            ResolvedKeywordFilter(rules: [hide, fold, highlight]).verdict(forSubject: subject),
            .hide(keyword: "代购")
        )
        XCTAssertEqual(
            ResolvedKeywordFilter(rules: [highlight, fold]).verdict(forSubject: subject),
            .fold(keyword: "二手")
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
            .highlight(colorHex: "#FFF3B0", keyword: "显卡")
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

    // MARK: - 规则怎么存

    func testRulesSurviveAnEncodeDecodeRoundTrip() {
        let rules = [
            KeywordFilterRule(keywords: "显卡,矿卡", action: .highlight, colorHex: "#C5E3FF"),
            KeywordFilterRule(keywords: "带货", action: .hide, isEnabled: false)
        ]
        XCTAssertEqual(KeywordFilterSettings.decode(KeywordFilterSettings.encode(rules)), rules)
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
