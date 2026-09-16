import Foundation

/// 一次请求有多要紧。
///
/// 只有两档，不是强度滑块：要么用户此刻正等着这一下，要么不是。中间档听起来更细腻，
/// 实际上没人分得清「稍微要紧一点」该排在哪儿，排序规则也会跟着含糊。
enum RequestPriority: Int, Sendable, Comparable {
    /// 用户正等着：翻页、点开帖子、提交回复、刷新。
    case userInitiated
    /// 补充信息，晚一点没关系：逐楼补作者资料、预读列表计数这一类。
    case background

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 当前这段代码算哪一档。
    ///
    /// 用 task-local 而不是给 `HTTPTransport.data(for:)` 添一个参数：优先级要从
    /// 「谁发起的」一路传到「谁在发」，中间隔着 store → service → client → transport
    /// 四层，逐层加参数会改一整条签名链，而沿途绝大多数调用点根本不关心这件事。
    /// `forumSiteDescriptor` 走环境也是同一个理由。
    ///
    /// **默认是 `.userInitiated`，后台请求要自己声明。** 反过来更省事，但那意味着
    /// 忘了标的地方会悄悄把用户的点击降级 —— 而这一整套东西正是为了不让那种事发生。
    @TaskLocal static var current: RequestPriority = .userInitiated

    /// 把这一段里发出的请求都算成后台的。
    ///
    /// task-local 会跟着 `await` 和子任务往下传，所以包住最外面那一层就够了，
    /// 不必逐个请求去标。
    /// `isolation` 显式带上，否则严格并发会把闭包当成跨隔离域传递的非 Sendable 值
    /// 而拒掉 —— 调用点大多在 `@MainActor` 的 store 里，闭包捕获的东西不是 Sendable。
    /// 带上它，闭包就还在调用方自己的隔离域里跑。
    static func inBackground<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $current.withValue(.background, operation: body, isolation: isolation)
    }
}

/// 一个站点的发送闸门：同时在飞几个、相邻两发至少隔多久、谁先走，以及站点说过
/// 「别发了」之后停多久。
///
/// **为什么不是各客户端里那个 `throttle()`。** 三个客户端原先各有一份「相邻两发隔
/// 280–320ms」的节流，做法是先把下一个时隙占掉再睡过去 —— 节奏是对的，但它只会
/// 排队，不会挑人。于是补作者属地那一下在 V2EX 上排了 176 发，第 176 发等到
/// 56 秒（176 × 320ms 正是那个数），而用户此刻点的那一下**排在它们后面**，
/// 还要再等一手。真正的毛病从来不是请求多，是它们和用户的点击抢同一条队。
///
/// 所以这里三件事一起给：
/// - **起飞间隔**继承原来那个数，节奏不变；
/// - **并发上限**管的是同时在飞几个。`URLSession` 自己有 `httpMaximumConnectionsPerHost`，
///   但它超出之后按先来后到自己排，排序权就落到了它手里 —— 我们要的是排序权；
/// - **优先级**：谁先走由 `RequestPriority` 决定，同档之内才按先来后到。
///
/// 每个**站点**一个实例，账号之间共用：限流是服务器按 host 算的，两个账号打的是
/// 同一台机器。
actor RequestScheduler {
    struct Pacing: Sendable {
        /// 同时在飞的上限。
        var maximumConcurrent: Int
        /// 相邻两发之间至少隔多久。管的是**起飞**，不是落地。
        var minimumStartInterval: Duration
    }

    /// 站点说「别发了」之后至少停多久。
    ///
    /// 对方给了 `Retry-After` 就听它的，但不低于这个数 —— 一个 `Retry-After: 1`
    /// 之后立刻又撞上去，只会把封锁续期。
    static let minimumCooldown: Duration = .seconds(60)

    private struct Waiter {
        let priority: RequestPriority
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let pacing: Pacing
    private let clock = ContinuousClock()

    private var inFlight = 0
    private var nextStartAt: ContinuousClock.Instant?
    private var coolingUntil: ContinuousClock.Instant?
    private var waiting: [Waiter] = []
    private var nextSequence: UInt64 = 0
    private var wakeTask: Task<Void, Never>?

    init(pacing: Pacing) {
        self.pacing = pacing
    }

    /// 排队等一个发送时隙。
    ///
    /// 返回 `false` 表示站点刚说过别发了，这一发不该出门 —— 而不是在这儿睡满冷却。
    /// 睡满意味着用户点一下、转两分钟圈；把话直说，他至少知道发生了什么。
    func acquire(priority: RequestPriority) async throws -> Bool {
        if let coolingUntil, clock.now < coolingUntil { return false }
        let sequence = nextSequence
        nextSequence &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append(
                    Waiter(priority: priority, sequence: sequence, continuation: continuation)
                )
                pump()
            }
        } onCancel: {
            Task { await self.abandon(sequence: sequence) }
        }
        return true
    }

    /// 交还时隙，顺便看一眼站点的答复里有没有「别发了」。
    ///
    /// 合成一个方法而不是 `release()` 加一个 `note...()`：两件事必须成对发生，
    /// 拆开就有人只写一半。`response` 为 nil 表示这一发是抛出去的（超时、断网），
    /// 那种失败不是限流。
    func release(observing response: HTTPURLResponse?) {
        inFlight -= 1
        if let response { noteIfThrottled(response) }
        pump()
    }

    /// 队伍里现在有几个在等。只给测试用 —— 用例要先确认「它们真的排进去了」，
    /// 否则「用户那一下插了队」可能只是因为后台那几个还没到。
    var waitingCountForTesting: Int { waiting.count }

    /// 站点当前是不是在冷却里。给测试和诊断用。
    var isCoolingDown: Bool {
        guard let coolingUntil else { return false }
        return clock.now < coolingUntil
    }

    /// 只认 429 和 503，**不认 403**。
    ///
    /// 油猴那边把 403 一并算进限流，因为在浏览器里分不出来。我们分得出：NodeSeek 的
    /// `/api/vote/*` 少了 `x-dynamic-sign` 就是 403，那是我们自己的 bug；别处的 403
    /// 多半是这个账号没权限或会话掉了。把它算成限流，会因为一个账号的会话过期，
    /// 把同一站点上另一个账号也停掉六十秒。
    private func noteIfThrottled(_ response: HTTPURLResponse) {
        guard response.statusCode == 429 || response.statusCode == 503 else { return }
        let requested = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
        let delay = max(Self.minimumCooldown, requested ?? .zero)
        coolingUntil = clock.now.advanced(by: delay)
    }

    /// `Retry-After` 有两种写法：秒数，或者一个 HTTP 日期。两种都认。
    static func retryAfter(
        _ value: String?,
        now: Date = Date()
    ) -> Duration? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if let seconds = Double(value) {
            return seconds > 0 ? .seconds(seconds) : .zero
        }
        guard let date = httpDateFormatter.date(from: value) else { return nil }
        return .seconds(max(0, date.timeIntervalSince(now)))
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private func abandon(sequence: UInt64) {
        guard let index = waiting.firstIndex(where: { $0.sequence == sequence }) else { return }
        let waiter = waiting.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// 能放几个就放几个。
    ///
    /// 放行一个之后 `nextStartAt` 就落在将来，所以紧接着那次递归必然走到「还没到点」
    /// 那一支、挂一个定时器回来，不会转下去。
    private func pump() {
        guard !waiting.isEmpty, inFlight < pacing.maximumConcurrent else { return }
        let now = clock.now
        if let nextStartAt, now < nextStartAt {
            scheduleWake(at: nextStartAt)
            return
        }
        guard let index = waiting.indices.min(by: { left, right in
            let a = waiting[left], b = waiting[right]
            return (a.priority, a.sequence) < (b.priority, b.sequence)
        }) else { return }
        let waiter = waiting.remove(at: index)
        inFlight += 1
        nextStartAt = now.advanced(by: pacing.minimumStartInterval)
        waiter.continuation.resume()
        pump()
    }

    private func scheduleWake(at instant: ContinuousClock.Instant) {
        // 只挂一个。`nextStartAt` 只会往后走，新来的等待者不会让它提前，
        // 所以在飞的那个定时器永远是对的那一个。
        guard wakeTask == nil else { return }
        wakeTask = Task { [clock] in
            try? await clock.sleep(until: instant)
            await self.wake()
        }
    }

    private func wake() {
        wakeTask = nil
        pump()
    }
}

/// 把一个传输套进某个站点的闸门里。
///
/// 做成装饰器而不是往各客户端里塞：三个客户端的鉴权、重试、失败形态各不相同，
/// 但「什么时候允许发出去」和这些都无关。夹在这一层，三个站一份实现，测试也能
/// 单独对着它跑。
struct ScheduledTransport: HTTPTransport {
    private let base: any HTTPTransport
    private let scheduler: RequestScheduler

    init(wrapping base: any HTTPTransport, scheduler: RequestScheduler) {
        self.base = base
        self.scheduler = scheduler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard try await scheduler.acquire(priority: RequestPriority.current) else {
            // 冷却中就地答一个 429，而不是自己造一种新错误。
            //
            // 这不是在伪造站点的答复 —— 站点刚刚**就是**这么说的，这里只是替它把
            // 话再说一遍。好处是三个客户端早就认得 429（一律翻成 `.rateLimited`，
            // NGA 还会据此不重试），不必为冷却在三处各写一遍翻译。
            return (Data(), Self.throttledResponse(for: request))
        }
        do {
            let result = try await base.data(for: request)
            await scheduler.release(observing: result.1)
            return result
        } catch {
            await scheduler.release(observing: nil)
            throw error
        }
    }

    private static func throttledResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "about:blank")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
