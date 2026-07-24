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
}

