import Foundation

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
