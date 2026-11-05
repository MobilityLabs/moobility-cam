import Foundation
import Testing
@testable import MoobilityCore

private func day(_ y: Int, _ m: Int, _ d: Int) -> CivilDay { CivilDay(year: y, month: m, day: d) }
private func md(_ m: Int, _ d: Int) -> MonthDay { MonthDay(month: m, day: d) }

@Suite struct TimingRuleTests {
    @Test func yearlyInclusiveEnds() {
        let rule = TimingRule.yearly(start: md(11, 13), end: md(11, 19))
        #expect(rule.matches(day: day(2026, 11, 13), minute: 0))
        #expect(rule.matches(day: day(2026, 11, 19), minute: 1439))
        #expect(!rule.matches(day: day(2026, 11, 12), minute: 720))
        #expect(!rule.matches(day: day(2026, 11, 20), minute: 720))
    }

    @Test func yearlyAcrossNewYear() {
        let rule = TimingRule.yearly(start: md(12, 20), end: md(1, 5))
        #expect(rule.matches(day: day(2026, 12, 31), minute: 0))
        #expect(rule.matches(day: day(2027, 1, 1), minute: 0))
        #expect(!rule.matches(day: day(2027, 1, 6), minute: 0))
        #expect(!rule.matches(day: day(2026, 12, 19), minute: 0))
    }

    @Test func yearlyFeb29OnlyInLeapYears() {
        let rule = TimingRule.yearly(start: md(2, 29), end: md(2, 29))
        #expect(rule.matches(day: day(2028, 2, 29), minute: 0))
        #expect(!rule.matches(day: day(2027, 2, 28), minute: 0))
        #expect(!rule.matches(day: day(2027, 3, 1), minute: 0))
    }

    @Test func yearlyLengthAcrossNewYear() {
        #expect(TimingRule.yearly(start: md(12, 20), end: md(1, 5)).yearlyLength == 17)
        #expect(TimingRule.yearly(start: md(11, 13), end: md(11, 19)).yearlyLength == 7)
        #expect(TimingRule.everyDay.yearlyLength == nil)
    }

    @Test func weeklyTimedWindow() {
        let rule = TimingRule.weekly(days: [6], window: .timed(start: 900, end: 1080))
        let friday = day(2026, 11, 6)
        #expect(friday.weekday == 6)
        #expect(rule.matches(day: friday, minute: 900))
        #expect(rule.matches(day: friday, minute: 1079))
        #expect(!rule.matches(day: friday, minute: 899))
        #expect(!rule.matches(day: friday, minute: 1080))
        #expect(!rule.matches(day: day(2026, 11, 5), minute: 1000))
    }

    @Test func weeklyOvernightBelongsToStartDay() {
        let rule = TimingRule.weekly(days: [6], window: .timed(start: 1320, end: 120))
        let friday = day(2026, 11, 6), saturday = day(2026, 11, 7)
        #expect(rule.matches(day: friday, minute: 1320))
        #expect(rule.matches(day: saturday, minute: 119))
        #expect(!rule.matches(day: saturday, minute: 120))
        #expect(!rule.matches(day: friday, minute: 60))
    }

    @Test func weeklyAllDay() {
        let rule = TimingRule.weekly(days: [6], window: .allDay)
        #expect(rule.matches(day: day(2026, 11, 6), minute: 0))
        #expect(rule.matches(day: day(2026, 11, 6), minute: 1439))
        #expect(!rule.matches(day: day(2026, 11, 7), minute: 0))
    }

    @Test func everyDayAlwaysMatches() {
        #expect(TimingRule.everyDay.matches(day: day(2026, 1, 1), minute: 0))
    }

    @Test func civilDayIgnoresUserCalendar() {
        let instant = Fixture.date(2026, 11, 20, 7, 30, 0, in: Fixture.calendar("UTC"))
        let la = TimeZone(identifier: "America/Los_Angeles")!
        #expect(CivilDay(instant, timeZone: la) == day(2026, 11, 19))
    }

    @Test func civilDayAcrossDaylightSaving() {
        let next = day(2027, 3, 13).adding(days: 1)
        #expect(next == day(2027, 3, 14))
        #expect(next.weekday == 1)
        #expect(day(2026, 12, 31).adding(days: 1) == day(2027, 1, 1))
        #expect(day(2027, 1, 1).adding(days: -1) == day(2026, 12, 31))
    }

    @Test func weeklyWallClockAcrossDaylightSaving() {
        let ny = TimeZone(identifier: "America/New_York")!
        let instant = Fixture.date(2027, 3, 14, 3, 10, 0)  // 03:10 EDT; clocks skipped 02:00–03:00
        let moment = LocalMoment(date: instant, timeZone: ny)
        #expect(moment.day == day(2027, 3, 14))
        #expect(moment.minute == 190)
        let rule = TimingRule.weekly(days: [1], window: .timed(start: 90, end: 210))
        #expect(rule.matches(day: moment.day, minute: moment.minute))
    }

    @Test func civilDaysOrderChronologically() {
        #expect(day(2026, 12, 31) < day(2027, 1, 1))
        #expect(day(2026, 11, 3) < day(2026, 11, 20))
    }
}
