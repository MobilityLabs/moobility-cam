import Foundation
import Testing
@testable import MoobilityCore

private let ny = TimeZone(identifier: "America/New_York")!
private let la = TimeZone(identifier: "America/Los_Angeles")!
private func md(_ m: Int, _ d: Int) -> MonthDay { MonthDay(month: m, day: d) }
private func day(_ y: Int, _ m: Int, _ d: Int) -> CivilDay { CivilDay(year: y, month: m, day: d) }
private func photo(_ name: String, _ rules: [TimingRule]) -> Photo { Photo(file: "\(name).png", title: name, rules: rules) }
private func ids(_ c: [Candidate]) -> [String] { c.map(\.id) }

private let fridayAfternoon = TimingRule.weekly(days: [6], window: .timed(start: 900, end: 1080))

@Suite struct LibraryTests {
    @Test func everyConflictRow() {
        let lib = Library(photos: [photo("year", [.yearly(start: md(11, 1), end: md(11, 30))]),
                                   photo("festival", [.holiday(id: .diwali, leadDays: 0)]),
                                   photo("week", [fridayAfternoon]),
                                   photo("daily", [.everyDay])], southern: false)
        let at = Fixture.date(2026, 11, 6, 16, 0, 0)
        #expect(ids(lib.ranked(at: at, timeZone: ny)) == ["week.png", "festival.png", "year.png", "daily.png", "season:autumn"])
    }

    @Test func shorterYearlyFirst() {
        let month = photo("month", [.yearly(start: md(11, 1), end: md(11, 30))])
        let week = photo("week", [.yearly(start: md(11, 13), end: md(11, 19))])
        let at = Fixture.date(2026, 11, 15)
        for photos in [[month, week], [week, month]] {
            #expect(Library(photos: photos, southern: false).ranked(at: at, timeZone: ny).first?.id == "week.png")
        }
    }

    @Test func shorterYearlyAcrossNewYear() {
        let long = photo("long", [.yearly(start: md(10, 1), end: md(3, 1))])
        let short = photo("short", [.yearly(start: md(12, 20), end: md(1, 5))])
        let lib = Library(photos: [long, short], southern: false)
        #expect(lib.ranked(at: Fixture.date(2027, 1, 1), timeZone: ny).first?.id == "short.png")
    }

    @Test func gridOrderBreaksTies() {
        let lib = Library(photos: [photo("b", [.everyDay]), photo("a", [.everyDay])], southern: false)
        #expect(Array(ids(lib.ranked(at: Fixture.date(2026, 11, 3), timeZone: ny)).prefix(2)) == ["b.png", "a.png"])
    }

    @Test func holidayTiesGoByGridOrder() {
        let lib = Library(photos: [photo("b", [.holiday(id: .christmas, leadDays: 0)]),
                                   photo("a", [.holiday(id: .kwanzaa, leadDays: 0)]),
                                   photo("c", [.holiday(id: .christmas, leadDays: 1)])], southern: false)
        let at = Fixture.date(2026, 12, 25)
        #expect(Array(ids(lib.ranked(at: at, timeZone: ny)).prefix(2)) == ["b.png", "c.png"])
    }

    @Test func photoRanksByBestRule() {
        let both = photo("both", [.everyDay, fridayAfternoon])
        let year = photo("year", [.yearly(start: md(11, 1), end: md(11, 30))])
        let lib = Library(photos: [year, both], southern: false)
        #expect(lib.ranked(at: Fixture.date(2026, 11, 6, 16, 0, 0), timeZone: ny).first?.id == "both.png")
        #expect(lib.ranked(at: Fixture.date(2026, 11, 6, 19, 0, 0), timeZone: ny).first?.id == "year.png")
    }

    @Test func noRulesNeverShows() {
        let lib = Library(photos: [photo("bare", [])], southern: false)
        #expect(ids(lib.ranked(at: Fixture.date(2026, 11, 3), timeZone: ny)) == ["season:autumn"])
    }

    @Test func alwaysEndsInSeason() {
        let ranked = Library(photos: [], southern: true).ranked(at: Fixture.date(2026, 11, 3), timeZone: ny)
        #expect(ranked == [.season(.spring)])
    }

    @Test func candidateIDsAndTitles() {
        #expect(Candidate.season(.autumn).title == "Autumn")
        #expect(Candidate.photo(Photo(file: "x.png", title: "X", rules: [])).title == "X")
    }

    @Test func seasonDatesNorthAndSouth() {
        #expect(Season.current(on: day(2026, 11, 3), southern: false) == .autumn)
        #expect(Season.current(on: day(2026, 11, 3), southern: true) == .spring)
        #expect(Season.current(on: day(2027, 1, 1), southern: false) == .winter)
        #expect(Season.current(on: day(2027, 1, 1), southern: true) == .summer)
        #expect(Season.current(on: day(2026, 12, 20), southern: false) == .autumn)
        #expect(Season.current(on: day(2026, 12, 21), southern: false) == .winter)
        #expect(Season.isSouthern(region: "AU"))
        #expect(!Season.isSouthern(region: "US"))
        #expect(!Season.isSouthern(region: nil))
    }

    @Test func oneSeasonEveryDayOfLeapYear() {
        for southern in [false, true] {
            var d = day(2028, 1, 1)
            while d.year == 2028 {
                let matching = Season.allCases.filter { season in
                    let dates = season.dates(southern: southern)
                    return TimingRule.yearly(start: dates.start, end: dates.end).matches(day: d, minute: 0)
                }
                #expect(matching == [Season.current(on: d, southern: southern)], "\(d)")
                d = d.adding(days: 1)
            }
        }
    }

    @Test func dayPlanIgnoresTimedWeekly() {
        let lib = Library(photos: [photo("week", [fridayAfternoon]), photo("daily", [.everyDay])], southern: false)
        let plan = lib.dayPlan(from: Fixture.date(2026, 11, 3), days: 14, timeZone: ny)
        #expect(plan.count == 1)
        #expect(plan[0].winner.id == "daily.png")
        #expect(plan[0].start == day(2026, 11, 3))
        #expect(plan[0].end == day(2026, 11, 16))
        #expect(plan[0].timedDays == [day(2026, 11, 6), day(2026, 11, 13)])
    }

    @Test func dayPlanAllDayWeeklyChangesWinner() {
        let lib = Library(photos: [photo("week", [.weekly(days: [6], window: .allDay)]), photo("daily", [.everyDay])], southern: false)
        let plan = lib.dayPlan(from: Fixture.date(2026, 11, 5), days: 3, timeZone: ny)
        #expect(plan.map(\.winner.id) == ["daily.png", "week.png", "daily.png"])
        #expect(plan.allSatisfy { $0.timedDays.isEmpty })
    }

    @Test func dayPlanMergesRuns() {
        let lib = Library(photos: [photo("nov", [.yearly(start: md(11, 1), end: md(11, 30))])], southern: false)
        let plan = lib.dayPlan(from: Fixture.date(2026, 11, 3), days: 30, timeZone: ny)
        #expect(plan.map(\.winner.id) == ["nov.png", "season:autumn"])
        #expect(plan[0].end == day(2026, 11, 30))
        #expect(plan[1].start == day(2026, 12, 1))
        #expect(plan[1].end == day(2026, 12, 2))
    }

    @Test func overrideEndsAtNewLocalMidnight() {
        var o = BackgroundOverride()
        o.set("x.png", at: Fixture.date(2026, 11, 3, 22, 0, 0), timeZone: ny)
        let laCalendar = Fixture.calendar("America/Los_Angeles")
        #expect(o.activeID(at: Fixture.date(2026, 11, 3, 21, 30, 0, in: laCalendar), timeZone: la) == "x.png")
        #expect(o.activeID(at: Fixture.date(2026, 11, 4, 0, 1, 0, in: laCalendar), timeZone: la) == nil)
    }

    @Test func overrideOnShortDaylightSavingDay() {
        var o = BackgroundOverride()
        o.set("x.png", at: Fixture.date(2027, 3, 14, 10, 0, 0), timeZone: ny)
        #expect(o.activeID(at: Fixture.date(2027, 3, 14, 23, 59, 0), timeZone: ny) == "x.png")
        #expect(o.activeID(at: Fixture.date(2027, 3, 15, 0, 0, 0), timeZone: ny) == nil)
    }

    @Test func clearingOverride() {
        var o = BackgroundOverride()
        let now = Fixture.date(2026, 11, 3)
        o.set("x.png", at: now, timeZone: ny)
        o.set(nil, at: now, timeZone: ny)
        #expect(o.activeID(at: now, timeZone: ny) == nil)
    }

    @Test func applyAppends() {
        #expect(WhenPresets.apply(.everyDay, to: [fridayAfternoon]) == [fridayAfternoon, .everyDay])
    }

    @Test func applyIgnoresDuplicate() {
        #expect(WhenPresets.apply(.everyDay, to: [.everyDay]) == [.everyDay])
    }

    @Test func upcomingFirstFourFromNov3() {
        let first = Holidays.upcoming(from: day(2026, 11, 3)).prefix(4).map(\.holiday.id)
        #expect(first == [.diwali, .thanksgivingUS, .hanukkah, .christmas])
    }

    @Test func spanShortText() {
        #expect((day(2026, 12, 4)...day(2026, 12, 12)).shortText == "Dec 4–12")
        #expect((day(2027, 12, 24)...day(2028, 1, 1)).shortText == "Dec 24–Jan 1")
        #expect((day(2026, 11, 26)...day(2026, 11, 26)).shortText == "Nov 26")
    }

    /// Final review: a Friday night window also runs early Saturday, so Saturday gets the mark too.
    @Test func overnightWeeklyMarksBothDays() {
        let late = TimingRule.weekly(days: [6], window: .timed(start: 1320, end: 120))
        let lib = Library(photos: [photo("late", [late]), photo("daily", [.everyDay])], southern: false)
        let plan = lib.dayPlan(from: Fixture.date(2026, 11, 5), days: 4, timeZone: ny)
        #expect(plan[0].timedDays == [day(2026, 11, 6), day(2026, 11, 7)])
    }

    /// Review Focus: the overridden or showing photo was removed; the next candidate shows.
    @Test func removedOverrideFallsBackToRanked() {
        let lib = Library(photos: [photo("daily", [.everyDay])], southern: false)
        var o = BackgroundOverride()
        let now = Fixture.date(2026, 11, 3)
        o.set("gone.png", at: now, timeZone: ny)
        #expect(lib.effective(at: now, override: o, timeZone: ny).first?.id == "daily.png")
        o.set("season:winter", at: now, timeZone: ny)
        #expect(lib.effective(at: now, override: o, timeZone: ny).first?.id == "season:winter")
        #expect(lib.effective(at: now, override: o, timeZone: ny).dropFirst().first?.id == "daily.png")
    }
}
