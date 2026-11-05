import Foundation

/// A month and day with no year. Feb 29 is valid and only occurs in leap years.
public struct MonthDay: Hashable, Sendable {
    public let month: Int
    public let day: Int

    public init(month: Int, day: Int) {
        self.month = month
        self.day = day
    }
}

public enum WeeklyWindow: Hashable, Sendable {
    case allDay
    /// Wall-clock minutes 0…1439. `end < start` runs overnight; `start == end` is invalid and matches nothing.
    case timed(start: Int, end: Int)
}

public enum TimingRule: Hashable, Sendable {
    case yearly(start: MonthDay, end: MonthDay)
    /// `days` uses 1 = Sunday … 7 = Saturday.
    case weekly(days: Set<Int>, window: WeeklyWindow)
    /// Shows for the whole holiday, starting `leadDays` earlier (0…30). Holiday rules have day resolution.
    case holiday(id: HolidayID, leadDays: Int)
    case everyDay

    /// Whether the rule is active at `minute` (wall-clock minutes since midnight) on `day`.
    public func matches(day: CivilDay, minute: Int) -> Bool {
        switch self {
        case .everyDay:
            return true

        case let .holiday(id, leadDays):
            return Holidays.isShowing(id, on: day, leadDays: leadDays)

        case let .yearly(start, end):
            let today = (day.month, day.day)
            let from = (start.month, start.day)
            let to = (end.month, end.day)
            return from <= to
                ? (from <= today && today <= to)
                : (today >= from || today <= to)  // crosses New Year

        case let .weekly(days, window):
            switch window {
            case .allDay:
                return days.contains(day.weekday)
            case let .timed(start, end):
                if start < end {
                    return days.contains(day.weekday) && start <= minute && minute < end
                }
                if end < start {
                    // Overnight: belongs to the day it starts on.
                    let startsToday = days.contains(day.weekday) && minute >= start
                    let startedYesterday = days.contains(day.adding(days: -1).weekday) && minute < end
                    return startsToday || startedYesterday
                }
                return false
            }
        }
    }

    /// Days a yearly rule covers in a 366-day year (Feb has 29), wrapping across New Year. Nil for other rules.
    public var yearlyLength: Int? {
        guard case let .yearly(start, end) = self else { return nil }
        let from = Self.ordinal(start)
        let to = Self.ordinal(end)
        return to >= from ? to - from + 1 : 366 - from + to + 1
    }

    private static let leapYearMonthLengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    /// 1-based day number within a leap year.
    private static func ordinal(_ monthDay: MonthDay) -> Int {
        let month = min(max(monthDay.month, 1), 12)
        return leapYearMonthLengths.prefix(month - 1).reduce(0, +) + monthDay.day
    }
}
