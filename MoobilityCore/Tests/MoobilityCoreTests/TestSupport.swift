import Foundation
@testable import MoobilityCore

/// Calendar + date helpers shared by the core tests.
enum Fixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MoobilityCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // MoobilityCore
        .deletingLastPathComponent()  // repo root

    static func calendar(_ tz: String = "America/New_York") -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0,
                     in cal: Calendar = calendar()) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }
}
