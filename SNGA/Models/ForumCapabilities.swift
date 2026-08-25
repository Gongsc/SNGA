import Foundation

/// 一个站点支持哪些功能。
///
/// 各站能做的事不一样：NGA 有评分、投票、子版面和私信，V2EX 没有子版面也没有站内
/// 私信，NodeSeek 又是另一套。界面据此决定**画不画**某个控件，而不是画出来、等用户
/// 点了再抛一个「不支持」。
///
/// 只有那些「没有数据也照样会画出来」的控件需要在这里门控。投票、评分、子版面、
/// 收藏夹这些本来就是数据为空时什么都不画，不必再问一遍能力。
struct ForumCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    /// 每日签到。
    static let checkIn = ForumCapabilities(rawValue: 1 << 0)
    /// 楼层点赞点踩。
    static let postVote = ForumCapabilities(rawValue: 1 << 1)
    /// 话题评分。
    static let topicRating = ForumCapabilities(rawValue: 1 << 2)
    /// 话题内投票。
    static let poll = ForumCapabilities(rawValue: 1 << 3)
    /// 版面下还有子版面。
    static let subforums = ForumCapabilities(rawValue: 1 << 4)
    /// 话题收藏支持分文件夹。
    static let topicFavoriteFolders = ForumCapabilities(rawValue: 1 << 5)
    /// 站内私信。
    static let privateMessages = ForumCapabilities(rawValue: 1 << 6)
    /// 全站搜索。
    static let globalSearch = ForumCapabilities(rawValue: 1 << 7)
    /// 按用户查看其发布的话题与回复。
    static let userActivities = ForumCapabilities(rawValue: 1 << 8)
    /// 回复正文用 UBB，配套工具条和表情。
    static let ubbEditor = ForumCapabilities(rawValue: 1 << 9)
    /// 匿名话题与匿名楼层。
    static let anonymousPosts = ForumCapabilities(rawValue: 1 << 10)

    static let all: ForumCapabilities = [
        .checkIn, .postVote, .topicRating, .poll, .subforums,
        .topicFavoriteFolders, .privateMessages, .globalSearch,
        .userActivities, .ubbEditor, .anonymousPosts
    ]
}
