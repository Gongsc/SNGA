import Foundation

/// NGA 怎么把一个版面编码成键，以及怎么读回来。
///
/// 这些是 NGA 一家的约定，所以不放在 `ForumID` 本体上：
///
/// - 普通版面的键就是 `fid` 的十进制写法，`414`、`-7`。
/// - 子版面的键是 `s` 加上 `stid`，`s35925536`。原先靠 `Int64.min` 偏移量区分，
///   那个编码只有作者看得懂，而且让同号的版面和子版面显示成同一个字符串。
/// - 持久化目前仍存那个 Int64，`ngaRawValue` 负责换算回去；C12 起改存键本身。
extension ForumID {
    private static let subforumPrefix = "s"
    private static let subforumThreshold = Int64.min / 2

    /// 普通版面。
    init(nga fid: Int64) {
        self.init(site: .nga, key: String(fid))
    }

    /// 子版面。
    init(ngaSubforum stid: Int64) {
        precondition(stid >= 0, "NGA stid must be non-negative")
        self.init(site: .nga, key: "\(Self.subforumPrefix)\(stid)")
    }

    /// 从老库里存的那个 Int64 还原。
    init(ngaStoredValue rawValue: Int64) {
        if rawValue < Self.subforumThreshold {
            self.init(ngaSubforum: rawValue &- Int64.min)
        } else {
            self.init(nga: rawValue)
        }
    }

    var ngaIsSubforum: Bool {
        site == .nga && key.hasPrefix(Self.subforumPrefix)
    }

    /// NGA 在 URL 里用的那个数字：普通版面是 fid，子版面是 stid。
    var ngaValue: Int64 {
        guard site == .nga else { return 0 }
        let digits = ngaIsSubforum ? String(key.dropFirst()) : key
        return Int64(digits) ?? 0
    }

    /// 请求里该用哪个查询参数名。
    var ngaQueryName: String {
        ngaIsSubforum ? "stid" : "fid"
    }

    /// 老库里那一列的值。非 NGA 的版面存不进去 —— C12 加上键那一列之后就不需要它了。
    var ngaRawValue: Int64? {
        guard site == .nga else { return nil }
        return ngaIsSubforum ? Int64.min &+ ngaValue : ngaValue
    }
}
