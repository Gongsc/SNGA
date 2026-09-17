import Foundation
import Observation

/// 新帖监控域：规则、轮询、结果与提醒。
///
/// 和 `ToolboxStore` 一样**不持有 `AppSession`**，理由也一样：它读的是一份匿名
/// 订阅，不认账号、不认登录态，一个账号都没有时照样能用，它的网络故障也不该显示成
/// 论坛的错误。
@MainActor
@Observable
final class TopicMonitorStore {
    /// 轮询间隔的上下限。下限不是拍的：订阅自己写着 `ttl` 60，比这更密只是在
    /// 反复取同一份缓存。
    static let intervalRange = 60...3600
    static let defaultInterval = 300

    private enum Key {
        static let isEnabled = "cn.snga.client.topicMonitor.enabled"
        static let rules = "cn.snga.client.topicMonitor.rules"
        static let interval = "cn.snga.client.topicMonitor.interval"
        static let watermark = "cn.snga.client.topicMonitor.watermark"
        static let hits = "cn.snga.client.topicMonitor.hits"
        static let notifies = "cn.snga.client.topicMonitor.notifies"
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Key.isEnabled)
            if isEnabled { start() } else { stop() }
        }
    }

    var sendsNotifications: Bool {
        didSet {
            guard sendsNotifications != oldValue else { return }
            defaults.set(sendsNotifications, forKey: Key.notifies)
        }
    }

    /// 用户写的规则原文，一行一条。
    private(set) var ruleText: String
    private(set) var rules: [TopicMonitorRule] = []
    private(set) var invalidRuleLines: [String] = []

    private(set) var intervalSeconds: Int
    private(set) var hits: [TopicMonitorHit] = []
    private(set) var isChecking = false
    private(set) var lastCheckedAt: Date?
    private(set) var lastErrorMessage: String?
    /// 成功检查了几轮、一共看过多少条、其中多少条命中。改规则时清零。
    private(set) var checkedRounds = 0
    private(set) var examinedCount = 0
    private(set) var matchedCount = 0

    var unreadCount: Int { hits.count { $0.isUnread } }

    /// 还没检查过。界面据此说「还没开始」，而不是「0 条结果」—— 后者像是
    /// 「查过了，什么都没有」。
    var hasNeverChecked: Bool { lastCheckedAt == nil }

    @ObservationIgnored private let feed: TopicMonitorFeed
    @ObservationIgnored private let notifications: NotificationService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var watermark: Int64?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(
        feed: TopicMonitorFeed = TopicMonitorFeed(),
        notifications: NotificationService = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.feed = feed
        self.notifications = notifications
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Key.isEnabled)
        // 提醒默认开着：监控这件事的全部意义就是不必自己盯着，一个不出声的
        // 监控等于没有。用户可以关，但不该由我们替他默认关掉。
        self.sendsNotifications = defaults.object(forKey: Key.notifies) as? Bool ?? true
        self.ruleText = defaults.string(forKey: Key.rules) ?? ""
        let stored = defaults.integer(forKey: Key.interval)
        self.intervalSeconds = Self.intervalRange.contains(stored)
            ? stored
            : Self.defaultInterval
        let mark = defaults.object(forKey: Key.watermark) as? NSNumber
        self.watermark = mark?.int64Value
        self.hits = Self.decodeHits(defaults.data(forKey: Key.hits))
        recompileRules()
    }

    // MARK: - 配置

    /// 改规则。
    ///
    /// **顺手把水位线和统计一起清掉，但结果留着。** 新规则和旧规则的统计放在一起
    /// 没有意义（「命中 3 条」说的是哪套规则的 3 条？）。水位线清掉则是为了让改完
    /// 之后的第一轮重新落位 —— 否则新规则要等到下一条新帖出现才第一次生效。
    /// 结果留着，是因为那是用户已经看到过的东西，替他清掉不合适。
    func updateRules(_ text: String) {
        ruleText = text
        defaults.set(text, forKey: Key.rules)
        recompileRules()
        watermark = nil
        defaults.removeObject(forKey: Key.watermark)
        checkedRounds = 0
        examinedCount = 0
        matchedCount = 0
    }

    func updateInterval(_ seconds: Int) {
        let clamped = min(max(seconds, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
        guard clamped != intervalSeconds else { return }
        intervalSeconds = clamped
        defaults.set(clamped, forKey: Key.interval)
        // 间隔变了就重起一轮，否则要等当前这一觉睡满才生效。
        if isEnabled { start() }
    }

    private func recompileRules() {
        let compiled = TopicMonitorRules.compile(ruleText)
        rules = compiled.rules
        invalidRuleLines = compiled.invalidLines
    }

    // MARK: - 轮询

    func start() {
        stop()
        guard isEnabled, !rules.isEmpty else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                guard let interval = self?.intervalSeconds else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// 本该跑却没在跑时补一下。已经在跑就别动它 —— `start()` 会先 `stop()`，
    /// 那会掐掉一次正在飞的检查。
    func startIfIdle() {
        guard pollTask == nil else { return }
        start()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 手动检查一次。正在检查时不重复发。
    func checkNow() async {
        await check()
    }

    private func check() async {
        guard !isChecking, !rules.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        let items: [TopicMonitorFeedItem]
        do {
            items = try await feed.load()
        } catch is CancellationError {
            return
        } catch {
            // 失败**不推进水位线**，也不清空结果。下一轮接着从原来的位置看。
            lastErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "订阅取不到"
            return
        }
        lastErrorMessage = nil
        lastCheckedAt = Date()

        let result = TopicMonitorPolicy.check(
            items: items,
            rules: rules,
            watermark: watermark
        )
        watermark = result.watermark
        defaults.set(NSNumber(value: result.watermark), forKey: Key.watermark)
        checkedRounds += 1
        examinedCount += result.examined
        matchedCount += result.matched

        guard !result.newHits.isEmpty else { return }
        hits = TopicMonitorPolicy.merging(hits, with: result.newHits)
        persistHits()
        guard sendsNotifications else { return }
        for hit in result.newHits {
            await notifications.notifyTopicMonitor(hit: hit)
        }
    }

    // MARK: - 结果

    func markAllHitsRead() {
        guard hits.contains(where: \.isUnread) else { return }
        for index in hits.indices {
            hits[index].isUnread = false
        }
        persistHits()
    }

    func markHitRead(id: Int64) {
        guard let index = hits.firstIndex(where: { $0.id == id }), hits[index].isUnread else {
            return
        }
        hits[index].isUnread = false
        persistHits()
    }

    func clearHits() {
        guard !hits.isEmpty else { return }
        hits = []
        persistHits()
    }

    private func persistHits() {
        defaults.set(try? JSONEncoder().encode(hits), forKey: Key.hits)
    }

    private static func decodeHits(_ data: Data?) -> [TopicMonitorHit] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([TopicMonitorHit].self, from: data)) ?? []
    }
}
