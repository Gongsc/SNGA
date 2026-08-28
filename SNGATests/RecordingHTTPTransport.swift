import Foundation
@testable import SNGA

/// 记下发出去的请求，好断言请求体到底长什么样。
///
/// 名字带 HTTP 是为了避开测试里另外两个私有的 `RecordingTransport` —— 它们
/// 各自只在自己的文件里用，这个是跨文件共用的。
final class RecordingHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let body: Data

    var requests: [URLRequest] { lock.withLock { _requests } }

    /// 按路径给不同的响应。取不到就用 `body` 兜底。
    private let byPath: [String: String]

    init(responding body: String, byPath: [String: String] = [:]) {
        self.body = Data(body.utf8)
        self.byPath = byPath
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let path = request.url?.path ?? ""
        let payload = byPath.first { path.hasPrefix($0.key) }?.value
        return (payload.map { Data($0.utf8) } ?? body, HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!)
    }
}
