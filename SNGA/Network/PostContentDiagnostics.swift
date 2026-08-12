import Foundation

/// 临时诊断：记录每层楼展开成多少个原生块、引用套了多深。
///
/// tid=47355984 会把主线程卡死，采样显示时间全花在反复的整窗 SwiftUI 布局上
/// （图片解码 0%、WebKit 0%、文字排版 0.4%），也就是视图树本身太大。但那个版面
/// 需要登录才能取到，无法在本机复现，只能让 app 自己把规模报出来。
///
/// 只在 Debug 构建里生效，只记「大得不正常」的楼层，写在 app 沙盒内的日志目录里。
/// 定位完成后应当整个删掉。
enum PostContentDiagnostics {
    #if DEBUG
    /// 低于这个规模的楼层是正常的，不必记录。
    private static let interestingBlocks = 60
    private static let interestingDepth = 6
    private static let lock = NSLock()
    private nonisolated(unsafe) static var peakBlocks = 0
    private nonisolated(unsafe) static var peakDepth = 0

    static func record(blocks: Int, depth: Int) {
        guard blocks >= interestingBlocks || depth >= interestingDepth else { return }
        let shouldWrite: Bool = lock.withLock {
            guard blocks > peakBlocks || depth > peakDepth else { return false }
            peakBlocks = max(peakBlocks, blocks)
            peakDepth = max(peakDepth, depth)
            return true
        }
        guard shouldWrite else { return }
        append("floor  blocks=\(blocks) quoteDepth=\(depth)")
    }

    /// 每加载一页楼层记一行：这一页到底长什么样 —— 多少层、几层走原生、
    /// 几层退回网页视图、最大的一层有多大。卡死时屏幕上是什么，看这行就知道。
    static func recordPage(
        topicID: Int64,
        page: Int,
        posts: [Post],
        hotReplies: [Post]
    ) {
        let all = posts + hotReplies
        let native = all.filter { $0.nativeContent != nil }
        let web = all.filter { $0.nativeContent == nil }
        let largestHTML = web.map(\.html.utf8.count).max() ?? 0
        let totalHTML = web.reduce(0) { $0 + $1.html.utf8.count }
        append(
            "page   tid=\(topicID) page=\(page) floors=\(posts.count)"
                + " hot=\(hotReplies.count) native=\(native.count) webview=\(web.count)"
                + " largestWebHTML=\(largestHTML)B totalWebHTML=\(totalHTML)B"
        )
    }

    private static func append(_ message: String) {
        let directory = RuntimeLogSettings.defaultDirectoryURL
        let file = directory.appending(path: "native-content-scale.log")
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
    #else
    static func record(blocks: Int, depth: Int) {}
    static func recordPage(topicID: Int64, page: Int, posts: [Post], hotReplies: [Post]) {}
    #endif
}
