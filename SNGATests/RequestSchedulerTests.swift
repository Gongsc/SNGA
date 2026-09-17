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

        let cooling = await scheduler.isCoolingDown()
        XCTAssertTrue(cooling)
        let background = try await scheduler.acquire(priority: .background)
        XCTAssertFalse(background, "冷却里还放行后台请求，等于把封锁续期")
    }

    /// **403 不算限流。** 闸门按站点共用，一个账号的会话过期不该把另一个也停掉；
    /// 而 NodeSeek 的 `/api/vote/*` 少了签名头也是 403，那是我们自己的 bug。
    func testA403IsNotTreatedAsThrottling() async throws {
        let scheduler = makeScheduler()
        let held = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(held)

        await scheduler.release(observing: response(status: 403))

        let cooling = await scheduler.isCoolingDown()
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

        let cooling = await scheduler.isCoolingDown()
        XCTAssertTrue(cooling)
        let background = try await scheduler.acquire(priority: .background)
        XCTAssertFalse(background)
    }

    /// **冷却绝不能挡住用户此刻在等的那一下。**
    ///
    /// 这一条是 2026-09-17 那个线上 bug 的定身符：NGA 上打开一个话题会按楼层去补
    /// 作者属地，那个 `ucp` 接口连着答十几个 503 —— 是**它自己**的防护，不是全站
    /// 限流。可冷却按主机记，于是接下来一分钟里用户点的每一下都拿到一个**我们自己
    /// 造的** 429，弹出「请求过于频繁」。日志里那几行 `durationMs=4 bytes=0` 就是它。
    ///
    /// 冷却的本意是别把事情弄得更糟，而拦下点击再伪造一句站点没说过的话，正是
    /// 把事情弄得更糟。
    func testACooldownNeverBlocksWhatTheUserIsWaitingFor() async throws {
        let scheduler = makeScheduler()
        let held = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(held)
        await scheduler.release(observing: response(status: 503))

        let cooling = await scheduler.isCoolingDown()
        XCTAssertTrue(cooling, "前提：确实进了冷却")

        let chore = try await scheduler.acquire(priority: .background)
        XCTAssertFalse(chore, "杂活该等着")

        let click = try await scheduler.acquire(priority: .userInitiated)
        XCTAssertTrue(click, "用户点的那一下被应用自己拦下来了")
        await scheduler.release(observing: nil)
    }

    /// 传输层那一侧同理：用户的请求照样出门，后台的才就地打回。
    func testOnlyBackgroundTrafficIsShortCircuitedWhileCooling() async throws {
        let scheduler = makeScheduler()
        let base = RecordingHTTPTransport(responding: "{}", status: 503)
        let transport = ScheduledTransport(wrapping: base, scheduler: scheduler)
        let request = URLRequest(url: URL(string: "https://example.com/a")!)

        _ = try await transport.data(for: request)
        XCTAssertEqual(base.requests.count, 1)

        await RequestPriority.$current.withValue(.background) {
            _ = try? await transport.data(for: request)
        }
        XCTAssertEqual(base.requests.count, 1, "冷却里的后台请求不该出门")

        _ = try await transport.data(for: request)
        XCTAssertEqual(base.requests.count, 2, "用户那一下必须真的发出去")
    }

    /// **冷却按主机分开。**
    ///
    /// 队列和节奏共用（那管的是我们自己往外发多快），冷却不能共用：V2EX 的主题
    /// 搜索接的是 SoV2EX，一个站外的第三方。它回一句 429 就把 V2EX 也停掉的话，
    /// 用户只是想翻个页，看到的却是「请求过于频繁」。
    func testACooldownOnOneHostDoesNotStopAnother() async throws {
        let scheduler = makeScheduler()
        let held = try await scheduler.acquire(priority: .userInitiated, host: "sov2ex.com")
        XCTAssertTrue(held)

        await scheduler.release(observing: response(status: 429), host: "sov2ex.com")

        let thirdPartyCooling = await scheduler.isCoolingDown(host: "sov2ex.com")
        XCTAssertTrue(thirdPartyCooling)
        let siteCooling = await scheduler.isCoolingDown(host: "www.v2ex.com")
        XCTAssertFalse(siteCooling, "第三方被限流，把站点本身也停掉了")

        let allowed = try await scheduler.acquire(priority: .background, host: "www.v2ex.com")
        XCTAssertTrue(allowed)
        let refused = try await scheduler.acquire(priority: .background, host: "sov2ex.com")
        XCTAssertFalse(refused)
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
            await Task.yield()
            // 取消**可能**赶在 acquire 之前落下，也可能没赶上 —— 那是这条用例
            // 本来就要覆盖的两种走法。没赶上时它会真的拿到那唯一一个时隙，
            // 这里必须还回去：不还，下面那一发会永远等下去，用例就从「断言失败」
            // 变成「超时」，而超时说明不了任何问题。
            let acquired = try await scheduler.acquire(priority: .userInitiated)
            if acquired { await scheduler.release(observing: nil) }
            return acquired
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

        let second = await RequestPriority.$current.withValue(.background) {
            try? await transport.data(for: request)
        }
        XCTAssertEqual(second?.1.statusCode, 429)
        XCTAssertEqual(base.requests.count, 1, "冷却里那一发后台请求不该真的出门")

        // 另一台主机不受牵连。
        _ = await RequestPriority.$current.withValue(.background) {
            try? await transport.data(
                for: URLRequest(url: URL(string: "https://elsewhere.example/a")!)
            )
        }
        XCTAssertEqual(base.requests.count, 2)
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
