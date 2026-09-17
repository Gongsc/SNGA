#if DEBUG
import Foundation

/// UI 测试里的订阅：答一份固定的 RSS，不出网。
///
/// 只换掉**传输**，`TopicMonitorFeed` 和它的解析照旧真跑一遍 —— 假的如果连解析
/// 都绕过去，这条路上出的错就一条也测不到了。
struct DebugRSSTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0"><channel>
        <title><![CDATA[NodeSeek]]></title>
        <item><title><![CDATA[测试用 vmiss 新机上架]]></title>
        <link>https://www.nodeseek.com/post-900001-1</link>
        <guid isPermaLink="false">900001</guid>
        <category><![CDATA[trade]]></category>
        <dc:creator><![CDATA[用户A]]></dc:creator>
        <pubDate>Wed, 16 Sep 2026 07:11:07 GMT</pubDate></item>
        <item><title><![CDATA[测试用 香港 年付 便宜鸡]]></title>
        <link>https://www.nodeseek.com/post-900000-1</link>
        <guid isPermaLink="false">900000</guid>
        <category><![CDATA[trade]]></category>
        <dc:creator><![CDATA[用户B]]></dc:creator>
        <pubDate>Wed, 16 Sep 2026 07:10:07 GMT</pubDate></item>
        </channel></rss>
        """
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url ?? TopicMonitorFeed.feedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/rss+xml"]
            )!
        )
    }
}

extension UserDefaults {
    /// UI 测试用的一套偏好设置：每次启动先清空，绝不碰用户真实的那一份。
    ///
    /// 监控的规则、检查进度和已收录的结果都落在 `UserDefaults` 里 —— 跑一次
    /// UI 测试就把开发者自己配的规则冲掉，那是不能接受的。
    /// `UserDefaults` 自己是线程安全的（Apple 文档明写），只是没标 `Sendable`。
    nonisolated(unsafe) static let uiTestingVolatile: UserDefaults = {
        let suite = "cn.snga.client.uitesting"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }()
}
#endif
