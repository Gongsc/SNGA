import Foundation

/// 一次 HTTP 往返。协议层不认识任何站点，也不认识小工具 —— 论坛适配层和
/// 小工具都从这里取传输，各自把失败翻译成自己领域的错误。
protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

enum HTTPTransportError: LocalizedError, Equatable, Sendable {
    /// 响应不是 HTTP 响应。调用方应翻译成自己领域的错误再抛给用户。
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "网络返回了无法识别的响应"
        }
    }
}

struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HTTPTransportError.invalidResponse
        }
        return (data, response)
    }
}
