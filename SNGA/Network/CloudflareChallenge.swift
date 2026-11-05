import Foundation

/// Cloudflare 把请求拦下来的形态。
///
/// 原先写在 `NodeSeekNetworkClient` 里。Linux.do 站前是同一家、同一种挑战页
/// （`cf-mitigated: challenge` + 一张「Just a moment...」），两份各写一遍迟早改漏一份，
/// 所以挪到这里共用。它不认识任何站点。
enum CloudflareChallenge {
    /// 要在看状态码之前判 —— 「请去验证」和「请去登录」是两条不同的恢复路径。
    ///
    /// `expectedJSON` 是承重的：「响应体是 HTML」只有在**问 JSON 的时候**才说明被拦截了。
    /// 网页请求本来就该拿到以 `<!DOCTYPE` 开头的东西，拿这条去判网页会把每一次成功
    /// 都当成挑战 —— NodeSeek 的列表页正是这样被自己判死过一次。
    static func isChallenge(
        status: Int,
        headers: [String: String],
        body: Data,
        expectedJSON: Bool
    ) -> Bool {
        if headers.first(where: { $0.key.caseInsensitiveCompare("cf-mitigated") == .orderedSame })?
            .value.caseInsensitiveCompare("challenge") == .orderedSame {
            return true
        }
        let head = String(data: body.prefix(600), encoding: .utf8) ?? ""
        // 挑战页本身的特征，网页和 JSON 都算。
        if head.contains("Just a moment") { return true }
        guard expectedJSON else { return false }
        return head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
    }
}
