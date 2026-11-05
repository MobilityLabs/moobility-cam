import Foundation

/// A calendar date with no time zone attached. All math uses a Gregorian calendar,
/// never `Calendar.current`, so a user's Buddhist or Hebrew calendar can't shift results.
public struct CivilDay: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local calendar day containing `date` in `timeZone`.
    public init(_ date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public static func < (lhs: CivilDay, rhs: CivilDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Day arithmetic runs in UTC from noon, so a daylight-saving change can't move the result.
    public func adding(days: Int) -> CivilDay {
        let calendar = Self.utcCalendar
        let shifted = calendar.date(byAdding: .day, value: days, to: noonUTC)!
        let c = calendar.dateComponents([.year, .month, .day], from: shifted)
        return CivilDay(year: c.year!, month: c.month!, day: c.day!)
    }

    /// 1 = Sunday … 7 = Saturday.
    public var weekday: Int {
        Self.utcCalendar.component(.weekday, from: noonUTC)
    }

    /// Noon UTC on this date: far enough from midnight that no offset moves it to another day.
    public var noonUTC: Date {
        Self.utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

/// An instant read off the wall clock of a time zone.
public struct LocalMoment: Sendable {
    public let day: CivilDay
    /// Minutes since local midnight by wall clock (`hour * 60 + minute`), 0…1439.
    /// On a daylight-saving day this follows the clock, not elapsed time.
    public let minute: Int

    public init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        day = CivilDay(year: c.year!, month: c.month!, day: c.day!)
        minute = c.hour! * 60 + c.minute!
    }
}
