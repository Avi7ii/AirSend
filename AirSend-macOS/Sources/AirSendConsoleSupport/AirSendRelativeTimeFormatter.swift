import Foundation

public enum AirSendRelativeTimeFormatter {
    public static func label(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))

        switch seconds {
        case ..<6:
            return "just now"
        case ..<60:
            return "\(seconds)s ago"
        case ..<3_600:
            return "\(seconds / 60)m ago"
        case ..<86_400:
            return "\(seconds / 3_600)h ago"
        default:
            return "\(seconds / 86_400)d ago"
        }
    }

    public static func nextLabelChangeDate(since date: Date, now: Date = Date()) -> Date {
        let elapsed = max(0, now.timeIntervalSince(date))
        let nextElapsed: TimeInterval

        switch elapsed {
        case ..<6:
            nextElapsed = 6
        case ..<60:
            nextElapsed = floor(elapsed) + 1
        case ..<3_600:
            nextElapsed = floor(elapsed / 60) * 60 + 60
        case ..<86_400:
            nextElapsed = floor(elapsed / 3_600) * 3_600 + 3_600
        default:
            nextElapsed = floor(elapsed / 86_400) * 86_400 + 86_400
        }

        return date.addingTimeInterval(nextElapsed)
    }

    public static func nextLabelChangeDate(for dates: [Date], now: Date = Date()) -> Date? {
        dates
            .map { nextLabelChangeDate(since: $0, now: now) }
            .filter { $0 > now }
            .min()
    }
}
