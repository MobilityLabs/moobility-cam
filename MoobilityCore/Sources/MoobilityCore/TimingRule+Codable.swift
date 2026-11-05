import Foundation

/// JSON shape, from the design spec's Storage section:
///
///     {"kind":"yearly","start":"MM-DD","end":"MM-DD"}
///     {"kind":"weekly","days":[6],"start":"HH:mm","end":"HH:mm"}   // no start or end: all day
///     {"kind":"holiday","holiday":"diwali","leadDays":0}
///     {"kind":"everyDay"}
///
/// Both directions are strict. An unknown kind or an out-of-range value throws, so one bad rule
/// makes the whole file unreadable (the store sets it aside) instead of quietly changing what
/// shows. Encoding refuses values decoding would refuse, so a bad in-memory rule can't poison the file.
extension TimingRule: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, start, end, days, holiday, leadDays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func corrupt(_ key: CodingKeys, _ why: String) -> DecodingError {
            DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: why)
        }
        func monthDay(_ key: CodingKeys) throws -> MonthDay {
            guard let value = try Self.parseMonthDay(container.decode(String.self, forKey: key)) else {
                throw corrupt(key, "expected a real date as MM-DD")
            }
            return value
        }
        func minute(_ text: String, _ key: CodingKeys) throws -> Int {
            guard let value = Self.parseMinute(text) else { throw corrupt(key, "expected a time as HH:mm") }
            return value
        }

        switch try container.decode(String.self, forKey: .kind) {
        case "yearly":
            self = .yearly(start: try monthDay(.start), end: try monthDay(.end))

        case "weekly":
            let days = try container.decode([Int].self, forKey: .days)
            guard days.allSatisfy({ Self.weekdays.contains($0) }) else { throw corrupt(.days, "weekday outside 1...7") }
            let window: WeeklyWindow
            switch (try container.decodeIfPresent(String.self, forKey: .start),
                    try container.decodeIfPresent(String.self, forKey: .end)) {
            case (nil, nil):
                window = .allDay
            case let (start?, end?):
                window = .timed(start: try minute(start, .start), end: try minute(end, .end))
            default:
                throw corrupt(.start, "start and end must both be present or both absent")
            }
            self = .weekly(days: Set(days), window: window)

        case "holiday":
            guard let id = HolidayID(rawValue: try container.decode(String.self, forKey: .holiday)) else {
                throw corrupt(.holiday, "unknown holiday")
            }
            let leadDays = try container.decode(Int.self, forKey: .leadDays)
            guard Self.leadDayRange.contains(leadDays) else { throw corrupt(.leadDays, "lead days outside 0...30") }
            self = .holiday(id: id, leadDays: leadDays)

        case "everyDay":
            self = .everyDay

        default:
            throw corrupt(.kind, "unknown rule kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func invalid(_ why: String) -> EncodingError {
            EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: why))
        }

        switch self {
        case let .yearly(start, end):
            guard Self.isValid(start), Self.isValid(end) else { throw invalid("date out of range") }
            try container.encode("yearly", forKey: .kind)
            try container.encode(Self.format(start), forKey: .start)
            try container.encode(Self.format(end), forKey: .end)

        case let .weekly(days, window):
            guard days.allSatisfy({ Self.weekdays.contains($0) }) else { throw invalid("weekday outside 1...7") }
            try container.encode("weekly", forKey: .kind)
            try container.encode(days.sorted(), forKey: .days)
            if case let .timed(start, end) = window {
                guard Self.minutes.contains(start), Self.minutes.contains(end) else {
                    throw invalid("minute outside 0...1439")
                }
                try container.encode(Self.format(minute: start), forKey: .start)
                try container.encode(Self.format(minute: end), forKey: .end)
            }

        case let .holiday(id, leadDays):
            guard Self.leadDayRange.contains(leadDays) else { throw invalid("lead days outside 0...30") }
            try container.encode("holiday", forKey: .kind)
            try container.encode(id.rawValue, forKey: .holiday)
            try container.encode(leadDays, forKey: .leadDays)

        case .everyDay:
            try container.encode("everyDay", forKey: .kind)
        }
    }

    // MARK: Ranges and text forms

    private static let weekdays = 1...7
    private static let minutes = 0...1439
    private static let leadDayRange = 0...30
    private static let monthLengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]  // Feb 29 is valid

    private static func isValid(_ monthDay: MonthDay) -> Bool {
        (1...12).contains(monthDay.month) && (1...monthLengths[monthDay.month - 1]).contains(monthDay.day)
    }

    private static func format(_ monthDay: MonthDay) -> String {
        String(format: "%02d-%02d", monthDay.month, monthDay.day)
    }

    private static func format(minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private static func parseMonthDay(_ text: String) -> MonthDay? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let month = twoDigits(parts[0]), let day = twoDigits(parts[1]) else { return nil }
        let value = MonthDay(month: month, day: day)
        return isValid(value) ? value : nil
    }

    private static func parseMinute(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = twoDigits(parts[0]), let minute = twoDigits(parts[1]),
              hour < 24, minute < 60 else { return nil }
        return hour * 60 + minute
    }

    private static func twoDigits(_ text: Substring) -> Int? {
        guard text.count == 2, text.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(text)
    }
}
