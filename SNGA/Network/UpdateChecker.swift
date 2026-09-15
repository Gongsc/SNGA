import Foundation

/// 仓库里最新的那个正式版本。
struct AppRelease: Equatable, Sendable {
    /// 版本号，已经去掉 tag 上可能带的 `v` 前缀。
    var version: String
    /// 这一版在 GitHub 上的页面，给「去看看」用。
    var pageURL: URL?
}

enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case updateAvailable(AppRelease)
}

protocol UpdateChecking: Sendable {
    /// 拿当前版本去问一次仓库。只回答「有没有更新」，不负责下载或安装。
    func checkForUpdate(currentVersion: String) async throws -> UpdateCheckResult
}

enum UpdateCheckError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case server(Int)
    /// GitHub 匿名接口是按 IP 每小时 60 次。撞上了要说人话，不能只报一个 403。
    case rateLimited
    /// 仓库一个 Release 都还没有。这不是错，但也没法比较。
    case noRelease

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "更新接口返回了无法识别的数据"
        case let .server(status):
            "暂时查不到更新（HTTP \(status)）"
        case .rateLimited:
            "查询太频繁，请过一会儿再试"
        case .noRelease:
            "仓库还没有发布任何版本"
        }
    }
}

/// 版本号比较。
///
/// 只认 `1.9.0` / `2.0.0` 这种点分数字，因为发版流程就只产生这种 tag（见
/// `release.yml`：tag 必须和 `MARKETING_VERSION` 对得上）。逐段按**数值**比，不能按
/// 字符串 —— `"10" < "9"` 在字符串序下成立，版本号上是反的。
///
/// 段数不齐时短的那边补零：`2.0` 和 `2.0.0` 是同一版，而 `2.0.1` 比 `2.0` 新。
enum AppVersionOrder {
    /// `candidate` 是不是比 `current` 新。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(numbers(in: candidate), numbers(in: current)) > 0
    }

    /// tag 上的 `v` 前缀顺手去掉。仓库的惯例是不带（`release.yml` 的 tag 模式就没有
    /// `v`），但这一条不值得赌 —— 真带上了，剩下的部分照样是能比的数字。
    /// 预发布后缀（`2.0.0-beta1`）在这里被截掉：`/releases/latest` 本来就不返回预发布，
    /// 万一拿到了，也按它前面的数字算，而不是整串解析失败当成没有更新。
    static func normalized(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        if let separator = value.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            value = String(value[value.startIndex..<separator])
        }
        return value
    }

    private static func numbers(in rawValue: String) -> [Int] {
        normalized(rawValue)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

/// 问 GitHub 要仓库最新的正式版本。
///
/// 走 `/releases/latest` 而不是 `/releases`：这个端点**本来就跳过草稿和预发布**，
/// 正好对上发版流程里「带后缀的 tag 按预发布处理」那一条 —— 用 beta 去提示所有人升级
/// 是不对的。代价是仓库一个正式版都没有时它回 404，单独翻译成 `.noRelease`。
///
/// 匿名请求，不带任何凭据：这是公开仓库的公开接口，也就没有钥匙串那摊事。
struct GitHubReleaseUpdateChecker: UpdateChecking {
    static let repositoryURL = URL(string: "https://github.com/Gongsc/SNGA")!

    private let transport: any HTTPTransport
    private let endpoint: URL

    init(
        transport: any HTTPTransport = URLSessionTransport(),
        endpoint: URL = URL(string: "https://api.github.com/repos/Gongsc/SNGA/releases/latest")!
    ) {
        self.transport = transport
        self.endpoint = endpoint
    }

    func checkForUpdate(currentVersion: String) async throws -> UpdateCheckResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("SNGA/1.0 (macOS; native client)", forHTTPHeaderField: "User-Agent")
        // GitHub 要求显式声明版本，否则哪天默认版本一换，字段就可能对不上了。
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.data(for: request)
        } catch HTTPTransportError.invalidResponse {
            throw UpdateCheckError.invalidResponse
        }

        switch response.statusCode {
        case 200..<300:
            break
        case 404:
            throw UpdateCheckError.noRelease
        case 403, 429:
            // 限流时 GitHub 回 403 而不是 429，靠这个头区分「被限流」和「真的没权限」。
            let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            throw remaining == "0" ? UpdateCheckError.rateLimited : .server(response.statusCode)
        default:
            throw UpdateCheckError.server(response.statusCode)
        }

        let release = try Self.release(from: data)
        return AppVersionOrder.isNewer(release.version, than: currentVersion)
            ? .updateAvailable(release)
            : .upToDate
    }

    /// 从 `/releases/latest` 的响应里取出版本和页面地址。
    static func release(from data: Data) throws -> AppRelease {
        struct Payload: Decodable {
            var tagName: String
            var htmlURL: String?

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
            }
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw UpdateCheckError.invalidResponse
        }
        let version = AppVersionOrder.normalized(payload.tagName)
        guard !version.isEmpty else { throw UpdateCheckError.invalidResponse }
        return AppRelease(
            version: version,
            pageURL: payload.htmlURL.flatMap(URL.init(string:))
        )
    }
}

#if DEBUG
/// UI 测试用的假实现：不发请求，也就不会因为 GitHub 限流或断网而红。
struct DebugUpdateChecker: UpdateChecking {
    var result: UpdateCheckResult = .upToDate
    var error: (any Error)?

    func checkForUpdate(currentVersion: String) async throws -> UpdateCheckResult {
        try await Task.sleep(for: .milliseconds(200))
        if let error { throw error }
        return result
    }
}
#endif
