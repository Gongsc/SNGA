import Foundation

/// 一个站点支持哪些功能。
///
/// 各站能做的事不一样：NGA 有评分、投票、子版面和私信，V2EX 没有子版面也没有站内
/// 私信，NodeSeek 又是另一套。界面据此决定**画不画**某个控件，而不是画出来、等用户
/// 点了再抛一个「不支持」。
///
/// 只有那些「没有数据也照样会画出来」的控件需要在这里门控。评分、子版面、收藏夹
/// 这些本来就是数据为空时什么都不画，不必再问一遍能力。
///
/// **门控要挡在调用层，不只是画不画。** 有些数据是主动去拉的 —— 版面收藏在启动、
/// 切账号和 ⌘R 时都会拉一次。光把界面藏起来，请求照样发，用户一登录就会看到一个
/// 「不支持」的报错。
struct ForumCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    /// 每日签到。
    static let checkIn = ForumCapabilities(rawValue: 1 << 0)
    /// 楼层可以表态。V2EX 的「感谢」也算，尽管它只有一个方向。
    static let postVote = ForumCapabilities(rawValue: 1 << 1)
    /// 表态有反方向。V2EX 只能感谢，没有踩。
    static let postDownvote = ForumCapabilities(rawValue: 1 << 11)
    /// 回复时可以引用某一层。V2EX 只能 @ 用户，引不了具体楼层。
    static let quotePost = ForumCapabilities(rawValue: 1 << 12)
    /// 话题评分。
    static let topicRating = ForumCapabilities(rawValue: 1 << 2)
    /// 话题内投票。
    static let poll = ForumCapabilities(rawValue: 1 << 3)
    /// 版面下还有子版面。
    static let subforums = ForumCapabilities(rawValue: 1 << 4)
    /// 可以收藏版面。NodeSeek 只能收藏话题。
    static let forumFavorites = ForumCapabilities(rawValue: 1 << 9)
    /// 话题收藏支持分文件夹。V2EX 和 NodeSeek 都是平铺一个列表。
    static let topicFavoriteFolders = ForumCapabilities(rawValue: 1 << 5)
    /// 站内私信。
    static let privateMessages = ForumCapabilities(rawValue: 1 << 6)
    /// 全站搜索。
    static let globalSearch = ForumCapabilities(rawValue: 1 << 7)
    /// 按用户查看其发布的话题与回复。
    static let userActivities = ForumCapabilities(rawValue: 1 << 8)
    /// 匿名话题与匿名楼层。
    static let anonymousPosts = ForumCapabilities(rawValue: 1 << 10)

    static let all: ForumCapabilities = [
        .checkIn, .postVote, .postDownvote, .quotePost, .topicRating, .poll,
        .subforums, .forumFavorites, .topicFavoriteFolders, .privateMessages,
        .globalSearch, .userActivities, .anonymousPosts
    ]
}
