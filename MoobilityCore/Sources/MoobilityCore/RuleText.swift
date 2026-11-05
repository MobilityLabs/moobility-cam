import Foundation

extension TimingRule {
    /// The short description a rule shows on its chip, such as "Every week · Fri 3–6 pm".
    /// `day` is today; only table-driven holidays need it, to notice they have run out of dates.
    public func chipText(from day: CivilDay) -> String {
        switch self {
        case .everyDay:
            return "Every day"

        case let .yearly(start, end):
            return "Every year · " + Self.dateRangeText(start, end)

        case let .weekly(days, window):
            var parts: [String] = []
            let names = days.sorted().compactMap { Self.dayNames.indices.contains($0 - 1) ? Self.dayNames[$0 - 1] : nil }
            if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
            if case let .timed(start, end) = window { parts.append(Self.timeRangeText(start, end)) }
            return parts.isEmpty ? "Every week" : "Every week · " + parts.joined(separator: " ")

        case let .holiday(id, leadDays):
            if let lastYear = Holidays.lastKnownYear(id), Holidays.nextSpan(id, from: day) == nil {
                return "No dates after \(lastYear)"
            }
            let name = Holidays.all.first { $0.id == id }?.name ?? id.rawValue
            let length = Holidays.displayLength(id)
            var detail = length == 1 ? "1 day" : "\(length) days"
            if leadDays > 0 { detail += ", \(leadDays) before" }
            return "Holiday · \(name) (\(detail))"
        }
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private static func monthName(_ month: Int) -> String {
        monthNames.indices.contains(month - 1) ? monthNames[month - 1] : String(month)
    }

    /// "Nov 20", "Nov 1–30", or "Dec 20–Jan 5".
    fileprivate static func dateRangeText(_ start: MonthDay, _ end: MonthDay) -> String {
        if start == end { return "\(monthName(start.month)) \(start.day)" }
        if start.month == end.month, start.day < end.day { return "\(monthName(start.month)) \(start.day)–\(end.day)" }
        return "\(monthName(start.month)) \(start.day)–\(monthName(end.month)) \(end.day)"
    }

    /// "3–6 pm" when both ends share a half of the day, else "11:30 am–1:30 pm".
    /// An overnight window keeps both marks: "1 pm–12:30 pm" is not a same-day range.
    private static func timeRangeText(_ start: Int, _ end: Int) -> String {
        let from = clockText(start), to = clockText(end)
        if from.period == to.period, start < end { return "\(from.time)–\(to.time) \(to.period)" }
        return "\(from.time) \(from.period)–\(to.time) \(to.period)"
    }

    /// Minutes since midnight as a 12-hour time; minutes appear only when non-zero. Midnight is "12 am", noon "12 pm".
    private static func clockText(_ minute: Int) -> (time: String, period: String) {
        let hour = minute / 60
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let time = minute % 60 == 0 ? "\(hour12)" : "\(hour12):" + String(format: "%02d", minute % 60)
        return (time, hour % 24 < 12 ? "am" : "pm")
    }
}

extension ClosedRange where Bound == CivilDay {
    /// "Nov 26", "Dec 4–12", or "Dec 24–Jan 1".
    public var shortText: String {
        TimingRule.dateRangeText(MonthDay(month: lowerBound.month, day: lowerBound.day),
                                 MonthDay(month: upperBound.month, day: upperBound.day))
    }
}
