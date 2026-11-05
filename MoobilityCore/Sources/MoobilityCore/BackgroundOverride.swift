import Foundation

/// A "show this one" choice that lasts until the next local midnight.
public struct BackgroundOverride: Sendable {
    private struct Entry: Sendable {
        let id: String
        let day: CivilDay
    }

    private var entry: Entry?

    public init() {}

    /// Passing nil clears the override. The choice is stored as the civil day it was made on.
    public mutating func set(_ id: String?, at date: Date, timeZone: TimeZone) {
        entry = id.map { Entry(id: $0, day: CivilDay(date, timeZone: timeZone)) }
    }

    /// The stored id while today (in `timeZone`) is still the day it was set; nil after that.
    public func activeID(at date: Date, timeZone: TimeZone) -> String? {
        guard let entry, entry.day == CivilDay(date, timeZone: timeZone) else { return nil }
        return entry.id
    }
}
