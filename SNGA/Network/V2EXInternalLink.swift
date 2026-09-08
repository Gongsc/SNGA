import Foundation

/// 认出正文里指向 V2EX 站内的链接，交给原生导航而不是浏览器。
///
/// 域名判断由 `ForumSiteDescriptor.internalDestination(for:)` 统一做过了，这里只管解析路径。
///
/// **用户链接一概交给浏览器。** 站点的用户地址里是用户名（`/member/Livid`、`/u/Livid`），
/// 而 `NGAInternalDestination.user` 要的是数字编号，中间那一步翻译得发一次
/// `/api/members/show.json` —— 这个函数是同步的，发不了。与其猜一个编号，
/// 不如让它照常在浏览器里打开。
enum V2EXInternalLink {
    // 正则直接写在用它的地方：`Regex` 不是 Sendable，存成静态属性过不了严格并发检查。
    //   /t/1240288        → 主题 1240288，页码在 ?p= 里
    //   /t/1240288#reply25 → 同上，锚点给的是楼层号
    //   /go/qna           → 节点 qna
    //   /recent           → 「最近主题」

    static func destination(for url: URL) -> NGAInternalDestination? {
        let path = url.path()
        if let match = path.wholeMatch(of: /^\/t\/(\d+)\/?$/), let tid = Int64(match.1) {
            let queried = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "p" }?
                .value
                .flatMap { Int($0) }
            // `#reply25` 是**楼层号**不是页码，站点每页 100 层。
            let floor = url.fragment()
                .flatMap { $0.wholeMatch(of: /reply(\d+)/) }
                .flatMap { Int($0.1) }
            return .topic(
                topicID: TopicID(rawValue: tid),
                page: queried ?? floor.map(V2EXEndpoint.page(ofFloor:)),
                postID: nil
            )
        }
        // 节点名不只有字母数字和连字符：站点里有 `c++`、`node.js` 这样的，
        // 所以放宽到「不含斜杠的一段」，把范围交给站点自己去认。
        if let match = path.wholeMatch(of: /^\/go\/([^\/]+)\/?$/) {
            let key = String(match.1).removingPercentEncoding ?? String(match.1)
            return .forum(V2EXEndpoint.forumID(key: key))
        }
        // 首页翻不下去（它是一屏精选），能一直往下翻的是 `/recent`，所以两个都落在它上面。
        if path == "/recent" || path == "/" || path.isEmpty {
            return .forum(V2EXEndpoint.forumID(key: V2EXEndpoint.recentKey))
        }
        return nil
    }
}
