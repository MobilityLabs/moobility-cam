import Foundation

public struct Photo: Hashable, Sendable {
    public var file: String
    public var title: String
    public var rules: [TimingRule]

    public init(file: String, title: String, rules: [TimingRule]) {
        self.file = file
        self.title = title
        self.rules = rules
    }
}

public enum Candidate: Hashable, Sendable {
    case photo(Photo)
    case season(Season)

    /// The photo's file name, or "season:autumn".
    public var id: String {
        switch self {
        case let .photo(photo): return photo.file
        case let .season(season): return "season:\(season.rawValue)"
        }
    }

    public var title: String {
        switch self {
        case let .photo(photo): return photo.title
        case let .season(season): return season.title
        }
    }
}

/// A run of consecutive days won by the same candidate.
public struct DaySegment: Hashable, Sendable {
    public let start: CivilDay
    public let end: CivilDay
    public let winner: Candidate
    /// Days in this run on which a timed weekly window applies: the day it starts, and for an
    /// overnight window the day after as well.
    public let timedDays: Set<CivilDay>
}

public struct Library: Sendable {
    public var photos: [Photo]
    public var southern: Bool

    public init(photos: [Photo], southern: Bool) {
        self.photos = photos
        self.southern = southern
    }

    /// Every photo with an active rule, best first, then the current season.
    /// Rank: weekly, holiday, yearly (shorter first), every day. Grid order breaks ties.
    public func ranked(at date: Date, timeZone: TimeZone) -> [Candidate] {
        let moment = LocalMoment(date: date, timeZone: timeZone)
        return ranked(on: moment.day, minute: moment.minute) { _ in true }
    }

    /// `ranked`, with the active override's candidate first. An id that matches no photo or season is ignored.
    public func effective(at date: Date, override current: BackgroundOverride, timeZone: TimeZone) -> [Candidate] {
        let byRank = ranked(at: date, timeZone: timeZone)
        guard let id = current.activeID(at: date, timeZone: timeZone), let chosen = candidate(withID: id) else {
            return byRank
        }
        return [chosen] + byRank.filter { $0.id != chosen.id }
    }

    /// Winners for `days` civil days from the day containing `from`. Timed weekly windows are left out,
    /// since they only change the photo for part of a day; their days are reported in `timedDays`.
    public func dayPlan(from date: Date, days: Int, timeZone: TimeZone) -> [DaySegment] {
        let first = CivilDay(date, timeZone: timeZone)
        var runs: [(start: CivilDay, end: CivilDay, winner: Candidate, timedDays: Set<CivilDay>)] = []
        for offset in 0..<max(days, 0) {
            let day = first.adding(days: offset)
            let winner = ranked(on: day, minute: 0) { !Self.isTimedWeekly($0) }[0]
            let timed: Set<CivilDay> = hasTimedWeekly(on: day) ? [day] : []
            if let last = runs.last, last.winner == winner {
                runs[runs.count - 1].end = day
                runs[runs.count - 1].timedDays.formUnion(timed)
            } else {
                runs.append((start: day, end: day, winner: winner, timedDays: timed))
            }
        }
        return runs.map { DaySegment(start: $0.start, end: $0.end, winner: $0.winner, timedDays: $0.timedDays) }
    }

    // MARK: Ranking

    /// Ranked candidates at a civil day and minute, considering only rules `include` accepts.
    /// Always ends with the current season, so the result is never empty.
    private func ranked(on day: CivilDay, minute: Int, including include: (TimingRule) -> Bool) -> [Candidate] {
        let scored = photos.enumerated().compactMap { index, photo -> (key: (Int, Int, Int), photo: Photo)? in
            let best = photo.rules
                .filter(include)
                .compactMap { Self.rank(of: $0, day: day, minute: minute) }
                .min { $0 < $1 }
            return best.map { (key: ($0.rank, $0.length, index), photo: photo) }
        }
        let ordered = scored.sorted { $0.key < $1.key }.map { Candidate.photo($0.photo) }
        return ordered + [.season(Season.current(on: day, southern: southern))]
    }

    /// Lower sorts first. Yearly rules break ties by how many days they cover.
    private static func rank(of rule: TimingRule, day: CivilDay, minute: Int) -> (rank: Int, length: Int)? {
        guard rule.matches(day: day, minute: minute) else { return nil }
        switch rule {
        case .weekly: return (1, 0)
        case .holiday: return (2, 0)
        case .yearly: return (3, rule.yearlyLength ?? 366)
        case .everyDay: return (4, 0)
        }
    }

    private static func isTimedWeekly(_ rule: TimingRule) -> Bool {
        if case .weekly(_, .timed) = rule { return true }
        return false
    }

    /// A window that runs overnight (end < start) also covers the early hours of the day after it starts.
    private func hasTimedWeekly(on day: CivilDay) -> Bool {
        let weekday = day.weekday
        let yesterday = day.adding(days: -1).weekday
        return photos.contains { photo in
            photo.rules.contains { rule in
                guard case let .weekly(days, .timed(start, end)) = rule else { return false }
                return days.contains(weekday) || (end < start && days.contains(yesterday))
            }
        }
    }

    private func candidate(withID id: String) -> Candidate? {
        if id.hasPrefix("season:") {
            return Season(rawValue: String(id.dropFirst("season:".count))).map(Candidate.season)
        }
        return photos.first { $0.file == id }.map(Candidate.photo)
    }
}

/// The "+ When" menu's edits to a photo's rules.
public enum WhenPresets {
    /// Appends `rule` unless the photo already has an identical one.
    public static func apply(_ rule: TimingRule, to rules: [TimingRule]) -> [TimingRule] {
        rules.contains(rule) ? rules : rules + [rule]
    }
}
