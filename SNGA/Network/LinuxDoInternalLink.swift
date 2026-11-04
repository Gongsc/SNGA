import Foundation

/// 认出正文里指向 Linux.do 站内的链接，交给原生导航而不是浏览器。
///
/// 域名判断由 `ForumSiteDescriptor.internalDestination(for:)` 统一做过了，这里只管解析路径。
enum LinuxDoInternalLink {
    //   /t/{slug}/{id}            → 话题
    //   /t/{slug}/{id}/{楼层号}   → 话题的那一楼所在页
    //   /t/{id}                   → 话题（没有 slug 的写法站点也认）
    //   /c/{slug…}/{id}           → 类别（子类别是两段 slug）
    //   /tag/{slug}/{id}          → 标签
    //   /latest                   → 话题（全站按最后回复）
    //
    // 用户链接（`/u/{名字}`）**不认**：地址里是名字，应用按编号认人，而这里是同步的、
    // 发不了那次翻译请求。猜一个编号比打开浏览器更糟 —— 和 V2EX 那条同一个道理。

    static func destination(for url: URL) -> NGAInternalDestination? {
        let path = url.path()
        if let match = path.wholeMatch(of: /^\/t\/(?:[^\/]+\/)?(\d+)(?:\/(\d+))?\/?$/),
           let tid = Int64(match.1) {
            let floor = match.2.flatMap { Int($0) }
            return .topic(
                topicID: TopicID(rawValue: tid),
                page: floor.map { ($0 - 1) / LinuxDoEndpoint.postsPerPage + 1 },
                postID: nil
            )
        }
        if let match = path.wholeMatch(of: /^\/c\/(?:[^\/]+\/)*?(\d+)(?:\/l\/[a-z]+)?\/?$/),
           let id = Int(match.1) {
            return .forum(LinuxDoEndpoint.forumID(categoryID: id))
        }
        if let match = path.wholeMatch(of: /^\/tag\/(?:[^\/]+\/)?(\d+)(?:\/l\/[a-z]+)?\/?$/),
           let id = Int(match.1) {
            return .forum(LinuxDoEndpoint.forumID(tagID: id))
        }
        if path == "/" || path.isEmpty || path == "/latest" {
            return .forum(LinuxDoEndpoint.forumID(key: LinuxDoEndpoint.latestKey))
        }
        return nil
    }
}
