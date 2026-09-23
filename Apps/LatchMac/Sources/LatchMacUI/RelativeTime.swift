import Foundation

/// Compact times for the sidebar, in T3's register: how long ago a session was active, and
/// how long a turn has been working.
enum RelativeTime {
    /// "now", "5m", "3h", "2d", "3w", then the date. Future times, from a clock that moved
    /// back, read as "now" rather than as a negative age.
    static func since(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        case ..<(35 * 86_400): return "\(Int(seconds / (7 * 86_400)))w"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar)
            return sameYear ? date.formatted(.dateTime.month(.abbreviated).day().locale(locale)) : date.formatted(style)
        }
    }

    /// "8s", "1m 12s", "1h 3m": a running turn's length, precise while it is short.
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    /// For VoiceOver, which should hear "3 hours ago", not "3h".
    static func spoken(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
