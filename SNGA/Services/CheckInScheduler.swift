import Foundation

/// 自动补签的开关。
enum AutoCheckInSettings {
    /// 默认**开着**。
    ///
    /// 这一下的主要用处不是替用户签到，而是**把状态问准**：站点的只读接口推不准
    /// 「今天签没签」时（见 `CheckInPolicy.shouldCheckIn` 上面那段），签到接口是
    /// 唯一一个会把话说死的地方 —— 已经签过就答「今日已签到」，没签过就顺手签了。
    /// 两种答复都让界面从此说实话。
    ///
    /// 它仍然是个写请求，所以给了开关，也**只走不赌的那一档**（NodeSeek 的固定
    /// 五个鸡腿，不是「试试手气」—— 替用户下注是另一回事，那得他自己点）。
    static let enabledKey = "checkIn.automatic"

    /// 现在到底开着没有。
    ///
    /// UI 测试**不许受开发者自己那份偏好摆布**，也不该默认替假账号签到 ——
    /// 「侧栏显示待签到」那条用例正是要看见那个提示。所以 `--uitesting` 下一律
    /// 当作关闭，要验补签的用例自己加 `--uitesting-auto-check-in`。
    /// （和监控那边换 `.uiTestingVolatile` 是同一个道理。）
    static var isEnabled: Bool {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitesting") {
            return arguments.contains("--uitesting-auto-check-in")
        }
#endif
        return UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

enum CheckInPolicy {
    static let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijingTimeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func shouldCheckIn(lastSuccessfulDay: String?, now: Date = Date()) -> Bool {
        lastSuccessfulDay != dayKey(for: now)
    }

    static func userFacingSuccessMessage(from source: String?) -> String {
        guard let source else { return "签到成功" }
        let message = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return "签到成功" }

        if message.hasPrefix("今日已签到（服务器时间 "), message.hasSuffix("）") {
            return message
        }
        if message.contains("任务进度更新") {
            return "签到成功（任务进度已更新）"
        }
        if message.contains("获得声望") {
            return "签到成功，获得声望"
        }
        if message.contains("签到成功") {
            return "签到成功"
        }
        if message.contains("已签到") || message.contains("已经签到") {
            return "今日已签到"
        }
        return "签到成功"
    }
}
