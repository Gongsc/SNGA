import XCTest
@testable import SNGA

/// 发送闸门。
///
/// 这套东西治的是一个具体的病：补作者属地那一下在 V2EX 上排了 176 发，用户此刻点的
/// 那一下排在它们后面。所以最要紧的一条断言是**顺序**，不是吞吐。
///
/// 用例一律把间隔设成零。真去睡 280ms 只是在测 `ContinuousClock`，还让套件变慢；
/// 要验的是排序、并发上限和冷却这三件事本身。
final class RequestSchedulerTests: XCTestCase {
    private func makeScheduler(
        maximumConcurrent: Int = 1,
        interval: Duration = .zero
    ) -> RequestScheduler {
        RequestScheduler(
            pacing: .init(
                maximumConcurrent: maximumConcurrent,
                minimumStartInterval: interval
            )
        )
    }

    /// 记下谁先走的。
    private actor Ledger {
        private(set) var started: [String] = []
        func note(_ name: String) { started.append(name) }
    }

    /// 闸门关着的时候排进来一批后台请求，再排一个用户请求 —— 放行时用户那个先走。
    ///
    /// 这就是那 56 秒的解法：队伍还是那条队伍，只是不再按先来后到。
    func testAUserRequestOvertakesBackgroundOnesAlreadyWaiting() async throws {
        let scheduler = makeScheduler(maximumConcurrent: 1)
        let ledger = Ledger()

        // 先占住唯一的时隙，让后面的都得排队。
        let held = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(held)

        var queued: [Task<Void, any Error>] = []
        for index in 0..<5 {
            queued.append(Task {
                try await RequestPriority.$current.withValue(.background) {
                    _ = try await scheduler.acquire(priority: RequestPriority.current)
                    await ledger.note("background\(index)")
                    await scheduler.release(observing: nil)
                }
            })
        }
        // 等这五个真的排进去，否则「插队」是因为它们还没到。
        try await waitUntil { await scheduler.waitingCountForTesting == 5 }

        queued.append(Task {
            _ = try await scheduler.acquire(priority: .userInitiated)
            await ledger.note("user")
            await scheduler.release(observing: nil)
        })
        try await waitUntil { await scheduler.waitingCountForTesting == 6 }

        await scheduler.release(observing: nil)
        for task in queued { try await task.value }

        let started = await ledger.started
        XCTAssertEqual(started.first, "user", "用户那一下排在五个后台请求之后才走")
        XCTAssertEqual(started.count, 6)
    }

    /// 同一档之内仍按先来后到 —— 优先级不该顺手把公平也一起取消了。
    func testSamePriorityKeepsArrivalOrder() async throws {
        let scheduler = makeScheduler(maximumConcurrent: 1)
        let ledger = Ledger()

        let held = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(held)

        var queued: [Task<Void, any Error>] = []
        for index in 0..<4 {
            queued.append(Task {
                _ = try await scheduler.acquire(priority: .background)
                await ledger.note("\(index)")
                await scheduler.release(observing: nil)
            })
            try await waitUntil { await scheduler.waitingCountForTesting == index + 1 }
        }

        await scheduler.release(observing: nil)
        for task in queued { try await task.value }

        let started = await ledger.started
        XCTAssertEqual(started, ["0", "1", "2", "3"])
    }

    /// 并发上限管的是同时在飞几个。超出的必须等着，而不是一起冲出去。
    func testConcurrencyCapHoldsTheRestBack() async throws {
        let scheduler = makeScheduler(maximumConcurrent: 2)

        let first = try await scheduler.acquire(priority: .userInitiated)
        let second = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(first && second)

        let third = Task {
            _ = try await scheduler.acquire(priority: .userInitiated)
            await scheduler.release(observing: nil)
        }
        try await waitUntil { await scheduler.waitingCountForTesting == 1 }
        XCTAssertFalse(third.isCancelled)

        await scheduler.release(observing: nil)
        try await third.value
        await scheduler.release(observing: nil)
    }

    /// 站点说 429，接下来一段时间就不该再发。
    func testA429StartsACooldown() async throws {
        let scheduler = makeScheduler()
        let held = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(held)

        await scheduler.release(observing: response(status: 429))

        let cooling = await scheduler.isCoolingDown
        XCTAssertTrue(cooling)
        let allowed = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertFalse(allowed, "冷却里还放行，等于把封锁续期")
    }

    /// **403 不算限流。** 闸门按站点共用，一个账号的会话过期不该把另一个也停掉；
    /// 而 NodeSeek 的 `/api/vote/*` 少了签名头也是 403，那是我们自己的 bug。
    func testA403IsNotTreatedAsThrottling() async throws {
        let scheduler = makeScheduler()
        let held = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(held)

        await scheduler.release(observing: response(status: 403))

        let cooling = await scheduler.isCoolingDown
        XCTAssertFalse(cooling)
        let allowed = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(allowed)
    }

    func testRetryAfterReadsBothSecondsAndHTTPDates() {
        XCTAssertEqual(RequestScheduler.retryAfter("120"), .seconds(120))
        XCTAssertNil(RequestScheduler.retryAfter(nil))
        XCTAssertNil(RequestScheduler.retryAfter("  "))
        XCTAssertNil(RequestScheduler.retryAfter("nonsense"))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let later = formatter.string(from: now.addingTimeInterval(90))

        XCTAssertEqual(RequestScheduler.retryAfter(later, now: now), .seconds(90))
        // 已经过去的日期算零，不是负数 —— 负的间隔会把冷却算成「早就到期」。
        let past = formatter.string(from: now.addingTimeInterval(-90))
        XCTAssertEqual(RequestScheduler.retryAfter(past, now: now), .seconds(0))
    }

    /// 一个 `Retry-After: 1` 之后立刻又撞上去，只会把封锁续期。
    func testCooldownNeverGoesBelowTheFloor() async throws {
        let scheduler = makeScheduler()
        let held = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(held)

        await scheduler.release(
            observing: response(status: 503, retryAfter: "1")
        )

        let cooling = await scheduler.isCoolingDown
        XCTAssertTrue(cooling)
        let allowed = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertFalse(allowed)
    }

    /// 取消一个排队中的请求，队伍不该就此卡住。
    func testCancellingAWaiterDoesNotStallTheQueue() async throws {
        let scheduler = makeScheduler(maximumConcurrent: 1)
        let held = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(held)

        let abandoned = Task {
            _ = try await scheduler.acquire(priority: .userInitiated)
        }
        try await waitUntil { await scheduler.waitingCountForTesting == 1 }
        abandoned.cancel()

        do {
            _ = try await abandoned.value
            XCTFail("取消了还照样放行")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        await scheduler.release(observing: nil)
        let recovered = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(recovered, "取消一个等待者之后，队伍卡住了")
    }

    /// 进来之前就已经取消的任务，不能把一个时隙带进坟墓。
    ///
    /// 这种任务的 `onCancel` 会先于 operation 跑完，那时队里还没有这个等待者 ——
    /// 不在排队之前再看一眼取消状态，它就会排进去再也没人叫醒，闸门少一个时隙。
    func testATaskCancelledBeforeItArrivesDoesNotSwallowASlot() async throws {
        let scheduler = makeScheduler(maximumConcurrent: 1)

        let doomed = Task {
            // 先让出一次，好让 cancel() 一定赶在 acquire 之前落下。
            await Task.yield()
            return try await scheduler.acquire(priority: .userInitiated)
        }
        doomed.cancel()
        _ = try? await doomed.value

        // 时隙必须还在。掉了的话下面这一发会永远挂着，用例会超时而不是失败 ——
        // 所以给它一个自己的期限。
        let acquired = Task { try await scheduler.acquire(priority: .userInitiated) }
        let outcome = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { try? await acquired.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                acquired.cancel()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        XCTAssertEqual(outcome, true, "取消掉的那一发把时隙带走了，闸门锁死")
    }

    /// 冷却里的那一发不出门，但答复要长得和站点自己说的一样 —— 三个客户端早就认得
    /// 429，不必为冷却在三处各写一遍翻译。
    func testTheTransportAnswers429WhileCoolingInsteadOfHittingTheNetwork() async throws {
        let scheduler = makeScheduler()
        let base = RecordingHTTPTransport(responding: "{}", status: 429)
        let transport = ScheduledTransport(wrapping: base, scheduler: scheduler)
        let request = URLRequest(url: URL(string: "https://example.com/a")!)

        let first = try await transport.data(for: request)
        XCTAssertEqual(first.1.statusCode, 429)
        XCTAssertEqual(base.requests.count, 1)

        let second = try await transport.data(for: request)
        XCTAssertEqual(second.1.statusCode, 429)
        XCTAssertEqual(base.requests.count, 1, "冷却里那一发不该真的出门")
    }

    /// 抛出去的那一发也要交还时隙，否则几次超时就把闸门锁死了。
    func testAThrownRequestStillReleasesItsSlot() async throws {
        let scheduler = makeScheduler(maximumConcurrent: 1)
        let transport = ScheduledTransport(
            wrapping: FailingTransport(), scheduler: scheduler
        )
        let request = URLRequest(url: URL(string: "https://example.com/a")!)

        for _ in 0..<3 {
            do {
                _ = try await transport.data(for: request)
                XCTFail("这个传输只会抛")
            } catch {
                XCTAssertTrue(error is URLError)
            }
        }

        let recovered = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(recovered, "时隙没还回来，闸门被锁死了")
    }

    // MARK: - 小工具

    private func response(
        status: Int,
        retryAfter: String? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: retryAfter.map { ["Retry-After": $0] }
        )!
    }

    /// 轮询一个条件成立。比写死一个 sleep 稳，也快得多。
    private func waitUntil(
        _ condition: () async -> Bool,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("等条件成立超时")
    }
}

private struct FailingTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.timedOut)
    }
}
