import Foundation

/// 新帖订阅：取一次 `rss.nodeseek.com`，解析成一串条目。
///
/// **一个 cookie 都不带，也不带 Referer 和 Origin。** 这是一份公开订阅，监控要的是
/// 「站上出了什么新帖」，和「我是谁」无关 —— 带上会话既没用，又把账号暴露给了一台
/// 不必知道它的机器。这一条和 `V2EXNetworkClient.getThirdParty` 是同一个理由，
/// 也是同一种做法：单独一个类型，而不是在通用发送函数里判一下域名 —— 判域名是
/// 一句可以被后来的人顺手删掉的条件。
///
/// 因此它也**不走 `ForumService`**：那条路上每个实例都揣着一个账号的 cookie。
struct TopicMonitorFeed: Sendable {
    /// 订阅地址。
    ///
    /// 这是 NodeSeek 的，**不覆盖别的站**。将来别的站有各自的订阅时，这里要按站点
    /// 分开，而不是把别人的帖子混进同一条流 —— 编号会撞。
    static let feedURL = URL(string: "https://rss.nodeseek.com/")!

    private let transport: any HTTPTransport

    init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    func load() async throws -> [TopicMonitorFeedItem] {
        var request = URLRequest(url: Self.feedURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(
            "application/rss+xml, application/xml, text/xml",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("SNGA/1.0 (macOS; native client)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ForumServiceError.server(response.statusCode)
        }
        return try TopicMonitorFeedParser.items(from: data)
    }
}

enum TopicMonitorFeedParser {
    /// 解析 RSS 2.0。
    ///
    /// 用 `XMLParser` 而不是 SwiftSoup：后者是 HTML 解析器，`<link>` 在 HTML 里是个
    /// 空元素，它的文本内容会被直接丢掉 —— 而那正是我们要的东西之一。
    static func items(from data: Data) throws -> [TopicMonitorFeedItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ForumServiceError.unexpectedPage("订阅不是一份能读的 XML")
        }
        // 一条都没有和「解析不出来」是两回事，但从这里分不开：订阅确实可能暂时为空。
        // 交给调用方按「这一轮没看到新东西」处理，水位线不动。
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private(set) var items: [TopicMonitorFeedItem] = []
        private var insideItem = false
        private var element = ""
        private var text = ""
        private var title = ""
        private var link = ""
        private var guid = ""
        private var category = ""
        private var author = ""
        private var pubDate = ""

        /// `pubDate` 是 RFC 822。`DateFormatter` 认它，但必须钉死 POSIX locale ——
        /// 月份名是英文的，跟着系统语言走会在非英文环境下全部解析失败。
        private static let rfc822: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter
        }()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            element = elementName
            text = ""
            if elementName == "item" {
                insideItem = true
                title = ""; link = ""; guid = ""; category = ""; author = ""; pubDate = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            defer { text = "" }
            guard insideItem else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "title": title = value
            case "link": link = value
            case "guid": guid = value
            case "category": category = value
            case "pubDate": pubDate = value
            case "dc:creator", "creator": author = value
            case "item":
                insideItem = false
                appendItem()
            default: break
            }
        }

        private func appendItem() {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty, let id = resolvedID() else { return }
            items.append(
                TopicMonitorFeedItem(
                    id: id,
                    title: trimmedTitle,
                    category: category.isEmpty ? nil : category,
                    author: author.isEmpty ? nil : author,
                    publishedAt: pubDate.isEmpty ? nil : Self.rfc822.date(from: pubDate),
                    link: URL(string: link)
                )
            )
        }

        /// 编号优先读 `guid`（这份订阅里它直接就是话题编号），读不出再从链接里取。
        ///
        /// 两条路都留着：`guid` 是这个站当下的写法，链接是 RSS 里更普遍的那一种。
        /// 只认 `guid` 的话，订阅哪天改成 permalink 形式，监控会安静地一条都不收。
        private func resolvedID() -> Int64? {
            if let value = Int64(guid.trimmingCharacters(in: .whitespacesAndNewlines)),
               value > 0 {
                return value
            }
            guard let url = URL(string: link),
                  let topicID = NodeSeekParser.topicID(fromPath: url.path) else {
                return nil
            }
            return topicID.rawValue
        }
    }
}
