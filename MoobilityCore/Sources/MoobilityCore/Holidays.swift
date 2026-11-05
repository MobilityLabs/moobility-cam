import Foundation

public enum HolidayID: String, CaseIterable, Sendable {
    case hanukkah, passover, roshHashanah, yomKippur, ramadan, eidAlFitr, eidAlAdha, lunarNewYear,
         diwali, holi, easter, thanksgivingUS, christmas, halloween, juneteenth, kwanzaa, newYear
}

public struct Holiday: Sendable {
    public let id: HolidayID
    public let name: String
    /// True when sources disagree or the date depends on moon sighting; the menu shows "≈".
    public let approximate: Bool
}

/// A fixed table of holidays. A holiday shows on civil days `anchor + offset - leadDays`
/// through `anchor + offset + length - 1`. Dates are never resolved as "the occurrence in
/// Gregorian year Y"; a day is tested by looking for an anchor within reach of it.
public enum Holidays {
    public static let all: [Holiday] = HolidayID.allCases.map { id in
        let row = HolidayRow.row(for: id)
        return Holiday(id: id, name: row.name, approximate: row.approximate)
    }

    public static func isShowing(_ id: HolidayID, on day: CivilDay, leadDays: Int) -> Bool {
        let row = HolidayRow.row(for: id)
        var anchor = day.adding(days: -row.offset - row.maxLength + 1)
        let last = day.adding(days: -row.offset + leadDays)
        while anchor <= last {
            if row.isAnchor(anchor), row.span(anchor: anchor, leadDays: leadDays).contains(day) {
                return true
            }
            anchor = anchor.adding(days: 1)
        }
        return false
    }

    /// The first span ending on or after `day`, without lead days; nil past a table's last year.
    public static func nextSpan(_ id: HolidayID, from day: CivilDay) -> ClosedRange<CivilDay>? {
        let row = HolidayRow.row(for: id)
        var anchor = day.adding(days: -row.offset - row.maxLength + 1)
        // Occurrences are at most about 400 days apart; look well past that before giving up.
        for _ in 0..<(row.maxLength + 800) {
            if row.isAnchor(anchor) {
                let span = row.span(anchor: anchor, leadDays: 0)
                if span.upperBound >= day { return span }
            }
            anchor = anchor.adding(days: 1)
        }
        return nil
    }

    /// Every holiday that has a next span, sorted by when that span starts.
    public static func upcoming(from day: CivilDay) -> [(holiday: Holiday, span: ClosedRange<CivilDay>)] {
        let found = all.enumerated().compactMap { index, holiday in
            nextSpan(holiday.id, from: day).map { (index: index, holiday: holiday, span: $0) }
        }
        return found
            .sorted { ($0.span.lowerBound, $0.index) < ($1.span.lowerBound, $1.index) }
            .map { (holiday: $0.holiday, span: $0.span) }
    }

    /// The last year a table-driven holiday has dates for; nil for holidays computed from a calendar.
    public static func lastKnownYear(_ id: HolidayID) -> Int? {
        guard case let .table(days) = HolidayRow.row(for: id).source else { return nil }
        return days.map(\.year).max()
    }

    /// The number of days a rule chip shows for a holiday. Ramadan's real length follows its month
    /// (29 or 30 days, plus the evening before), so it reads as a flat 30.
    static func displayLength(_ id: HolidayID) -> Int {
        switch HolidayRow.row(for: id).length {
        case let .days(n): return n
        case .ummAlQuraMonthPlusOne: return 30
        }
    }
}

private struct HolidayRow: Sendable {
    enum Source: Sendable {
        case hebrew(month: Int, day: Int)
        case ummAlQura(month: Int, day: Int)
        /// Chinese calendar date, never in a leap month.
        case chinese(month: Int, day: Int)
        case table(Set<CivilDay>)
        /// Easter Sunday by the anonymous Gregorian computus.
        case easter
        case nthWeekday(n: Int, weekday: Int, month: Int)
        case fixed(month: Int, day: Int)
    }

    enum Length: Sendable {
        case days(Int)
        /// The Umm al-Qura month the anchor falls in, plus one (Ramadan runs through its last day).
        case ummAlQuraMonthPlusOne
    }

    let name: String
    let approximate: Bool
    let source: Source
    let offset: Int
    let length: Length

    /// The longest length this row can have, for sizing the candidate range.
    var maxLength: Int {
        switch length {
        case let .days(n): return n
        case .ummAlQuraMonthPlusOne: return 31
        }
    }

    func span(anchor: CivilDay, leadDays: Int) -> ClosedRange<CivilDay> {
        let days: Int
        switch length {
        case let .days(n):
            days = n
        case .ummAlQuraMonthPlusOne:
            days = (Self.ummAlQura.range(of: .day, in: .month, for: anchor.noonUTC)?.count ?? 30) + 1
        }
        return anchor.adding(days: offset - leadDays)...anchor.adding(days: offset + days - 1)
    }

    func isAnchor(_ day: CivilDay) -> Bool {
        switch source {
        case let .hebrew(month, dayOfMonth):
            let c = Self.hebrew.dateComponents([.month, .day], from: day.noonUTC)
            return c.month == month && c.day == dayOfMonth
        case let .ummAlQura(month, dayOfMonth):
            let c = Self.ummAlQura.dateComponents([.month, .day], from: day.noonUTC)
            return c.month == month && c.day == dayOfMonth
        case let .chinese(month, dayOfMonth):
            let c = Self.chinese.dateComponents([.month, .day, .isLeapMonth], from: day.noonUTC)
            return c.month == month && c.day == dayOfMonth && c.isLeapMonth != true
        case let .table(days):
            return days.contains(day)
        case .easter:
            return day == Self.easterSunday(year: day.year)
        case let .nthWeekday(n, weekday, month):
            return day.month == month && day.weekday == weekday && (day.day - 1) / 7 == n - 1
        case let .fixed(month, dayOfMonth):
            return day.month == month && day.day == dayOfMonth
        }
    }

    // MARK: Calendars

    private static func utcCalendar(_ identifier: Calendar.Identifier) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static let hebrew = utcCalendar(.hebrew)
    private static let ummAlQura = utcCalendar(.islamicUmmAlQura)
    private static let chinese = utcCalendar(.chinese)

    /// Anonymous Gregorian algorithm (Meeus/Jones/Butcher).
    private static func easterSunday(year: Int) -> CivilDay {
        let a = year % 19
        let b = year / 100, c = year % 100
        let d = b / 4, e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return CivilDay(year: year, month: month, day: day)
    }

    // MARK: Rows

    /// Main days from two independent sources that agree. Holi 2026 has passed and is left out.
    private static let diwaliDays: Set<CivilDay> = [
        CivilDay(year: 2026, month: 11, day: 8),
        CivilDay(year: 2027, month: 10, day: 29),
        CivilDay(year: 2028, month: 10, day: 17),
        CivilDay(year: 2029, month: 11, day: 5),
        CivilDay(year: 2030, month: 10, day: 26),
    ]

    private static let holiDays: Set<CivilDay> = [
        CivilDay(year: 2027, month: 3, day: 22),
        CivilDay(year: 2028, month: 3, day: 11),
        CivilDay(year: 2029, month: 3, day: 1),
        CivilDay(year: 2030, month: 3, day: 20),
    ]

    static func row(for id: HolidayID) -> HolidayRow {
        switch id {
        case .hanukkah:
            return HolidayRow(name: "Hanukkah", approximate: false, source: .hebrew(month: 3, day: 25), offset: -1, length: .days(9))
        case .passover:
            return HolidayRow(name: "Passover", approximate: false, source: .hebrew(month: 8, day: 15), offset: -1, length: .days(9))
        case .roshHashanah:
            return HolidayRow(name: "Rosh Hashanah", approximate: false, source: .hebrew(month: 1, day: 1), offset: -1, length: .days(3))
        case .yomKippur:
            return HolidayRow(name: "Yom Kippur", approximate: false, source: .hebrew(month: 1, day: 10), offset: -1, length: .days(2))
        case .ramadan:
            return HolidayRow(name: "Ramadan", approximate: true, source: .ummAlQura(month: 9, day: 1), offset: -1, length: .ummAlQuraMonthPlusOne)
        case .eidAlFitr:
            return HolidayRow(name: "Eid al-Fitr", approximate: true, source: .ummAlQura(month: 10, day: 1), offset: -1, length: .days(4))
        case .eidAlAdha:
            return HolidayRow(name: "Eid al-Adha", approximate: true, source: .ummAlQura(month: 12, day: 10), offset: -1, length: .days(5))
        case .lunarNewYear:
            return HolidayRow(name: "Lunar New Year", approximate: false, source: .chinese(month: 1, day: 1), offset: 0, length: .days(7))
        case .diwali:
            return HolidayRow(name: "Diwali", approximate: true, source: .table(diwaliDays), offset: -2, length: .days(5))
        case .holi:
            return HolidayRow(name: "Holi", approximate: true, source: .table(holiDays), offset: -1, length: .days(2))
        case .easter:
            return HolidayRow(name: "Easter", approximate: false, source: .easter, offset: -2, length: .days(3))
        case .thanksgivingUS:
            return HolidayRow(name: "Thanksgiving (US)", approximate: false, source: .nthWeekday(n: 4, weekday: 5, month: 11), offset: 0, length: .days(1))
        case .christmas:
            return HolidayRow(name: "Christmas", approximate: false, source: .fixed(month: 12, day: 25), offset: 0, length: .days(1))
        case .halloween:
            return HolidayRow(name: "Halloween", approximate: false, source: .fixed(month: 10, day: 31), offset: 0, length: .days(1))
        case .juneteenth:
            return HolidayRow(name: "Juneteenth", approximate: false, source: .fixed(month: 6, day: 19), offset: 0, length: .days(1))
        case .kwanzaa:
            return HolidayRow(name: "Kwanzaa", approximate: false, source: .fixed(month: 12, day: 26), offset: 0, length: .days(7))
        case .newYear:
            return HolidayRow(name: "New Year", approximate: false, source: .fixed(month: 12, day: 31), offset: 0, length: .days(2))
        }
    }
}
