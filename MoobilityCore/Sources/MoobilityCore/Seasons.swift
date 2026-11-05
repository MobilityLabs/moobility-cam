import Foundation

/// The built-in fallback images. Dates are fixed; a southern-hemisphere region swaps spring with
/// autumn and summer with winter, keeping the same date ranges.
public enum Season: String, CaseIterable, Sendable {
    case spring, summer, autumn, winter

    public var title: String {
        switch self {
        case .spring: return "Spring"
        case .summer: return "Summer"
        case .autumn: return "Autumn"
        case .winter: return "Winter"
        }
    }

    private static let southernRegions: Set<String> = ["AR", "AU", "BO", "BR", "CL", "NZ", "PE", "PY", "UY", "ZA"]

    public static func isSouthern(region: String?) -> Bool {
        guard let region else { return false }
        return southernRegions.contains(region)
    }

    /// The one season whose dates contain `day`.
    public static func current(on day: CivilDay, southern: Bool) -> Season {
        allCases.first { season in
            let range = season.dates(southern: southern)
            return TimingRule.yearly(start: range.start, end: range.end).matches(day: day, minute: 0)
        } ?? .winter  // unreachable: the four ranges cover every date, including Feb 29
    }

    public func dates(southern: Bool) -> (start: MonthDay, end: MonthDay) {
        let northern = southern ? opposite : self
        switch northern {
        case .spring: return (MonthDay(month: 3, day: 20), MonthDay(month: 6, day: 20))
        case .summer: return (MonthDay(month: 6, day: 21), MonthDay(month: 9, day: 21))
        case .autumn: return (MonthDay(month: 9, day: 22), MonthDay(month: 12, day: 20))
        case .winter: return (MonthDay(month: 12, day: 21), MonthDay(month: 3, day: 19))
        }
    }

    private var opposite: Season {
        switch self {
        case .spring: return .autumn
        case .summer: return .winter
        case .autumn: return .spring
        case .winter: return .summer
        }
    }
}
