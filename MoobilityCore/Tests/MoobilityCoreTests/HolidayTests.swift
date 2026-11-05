import Foundation
import Testing
@testable import MoobilityCore

/// Expected dates come from outside sources (hebcal, timeanddate, published Umm al-Qura tables),
/// never from Foundation's own output.
private func shows(_ id: HolidayID, _ y: Int, _ m: Int, _ d: Int, lead: Int = 0) -> Bool {
    Holidays.isShowing(id, on: CivilDay(year: y, month: m, day: d), leadDays: lead)
}

@Suite struct HolidayTests {
    @Test func hanukkah2026() {
        #expect(!shows(.hanukkah, 2026, 12, 3))
        #expect(shows(.hanukkah, 2026, 12, 4))
        #expect(shows(.hanukkah, 2026, 12, 12))
        #expect(!shows(.hanukkah, 2026, 12, 13))
    }

    @Test func hanukkahCrossesNewYear() {
        #expect(shows(.hanukkah, 2027, 12, 24))
        #expect(shows(.hanukkah, 2028, 1, 1))
        #expect(!shows(.hanukkah, 2028, 1, 2))
    }

    @Test func passoverLeapAndCommonYears() {
        #expect(shows(.passover, 2027, 4, 21))
        #expect(shows(.passover, 2027, 4, 29))
        #expect(!shows(.passover, 2027, 4, 20))
        #expect(!shows(.passover, 2027, 4, 30))
        #expect(shows(.passover, 2028, 4, 10))
        #expect(shows(.passover, 2028, 4, 18))
        #expect(!shows(.passover, 2028, 4, 9))
    }

    @Test func roshHashanahAndYomKippur() {
        #expect(shows(.roshHashanah, 2027, 10, 1))
        #expect(shows(.roshHashanah, 2027, 10, 3))
        #expect(!shows(.roshHashanah, 2027, 10, 4))
        #expect(shows(.yomKippur, 2027, 10, 10))
        #expect(shows(.yomKippur, 2027, 10, 11))
        #expect(!shows(.yomKippur, 2027, 10, 12))
    }

    @Test func lunarNewYearMainDays() {
        #expect(shows(.lunarNewYear, 2027, 2, 6))
        #expect(shows(.lunarNewYear, 2027, 2, 12))
        #expect(!shows(.lunarNewYear, 2027, 2, 5))
        #expect(!shows(.lunarNewYear, 2027, 2, 13))
        #expect(shows(.lunarNewYear, 2028, 1, 26))
        #expect(shows(.lunarNewYear, 2030, 2, 3))
    }

    @Test func eidAlFitr2027() {
        #expect(shows(.eidAlFitr, 2027, 3, 8))
        #expect(shows(.eidAlFitr, 2027, 3, 11))
        #expect(!shows(.eidAlFitr, 2027, 3, 7))
        #expect(!shows(.eidAlFitr, 2027, 3, 12))
    }

    @Test func eidAlAdha2027() {
        #expect(shows(.eidAlAdha, 2027, 5, 15))
        #expect(shows(.eidAlAdha, 2027, 5, 19))
        #expect(!shows(.eidAlAdha, 2027, 5, 14))
        #expect(!shows(.eidAlAdha, 2027, 5, 20))
    }

    @Test func ramadanTwiceIn2030() {
        #expect(shows(.ramadan, 2030, 1, 5))
        #expect(shows(.ramadan, 2030, 12, 26))
        #expect(!shows(.ramadan, 2030, 7, 1))
    }

    @Test func ramadanLastDayFollowsTheMonth() {
        #expect(shows(.ramadan, 2026, 3, 19))
        #expect(!shows(.ramadan, 2026, 3, 20))
        #expect(shows(.ramadan, 2026, 2, 17))
        #expect(!shows(.ramadan, 2026, 2, 16))
    }

    @Test func diwali() {
        #expect(shows(.diwali, 2026, 11, 6))
        #expect(shows(.diwali, 2026, 11, 10))
        #expect(!shows(.diwali, 2026, 11, 5))
        #expect(!shows(.diwali, 2026, 11, 11))
        #expect(shows(.diwali, 2027, 10, 29))
        #expect(shows(.diwali, 2029, 11, 5))
    }

    @Test func diwaliPastTableDoesNotMatch() {
        var d = CivilDay(year: 2031, month: 1, day: 1)
        while d.year == 2031 {
            #expect(!Holidays.isShowing(.diwali, on: d, leadDays: 0))
            d = d.adding(days: 1)
        }
        #expect(Holidays.nextSpan(.diwali, from: CivilDay(year: 2031, month: 1, day: 1)) == nil)
        #expect(Holidays.lastKnownYear(.diwali) == 2030)
        #expect(Holidays.lastKnownYear(.hanukkah) == nil)
    }

    @Test func holi() {
        #expect(shows(.holi, 2027, 3, 21))
        #expect(shows(.holi, 2027, 3, 22))
        #expect(!shows(.holi, 2027, 3, 20))
        #expect(!shows(.holi, 2027, 3, 23))
    }

    @Test func easter() {
        #expect(shows(.easter, 2027, 3, 26))
        #expect(shows(.easter, 2027, 3, 28))
        #expect(!shows(.easter, 2027, 3, 25))
        #expect(!shows(.easter, 2027, 3, 29))
        #expect(shows(.easter, 2030, 4, 21))
    }

    @Test func thanksgiving() {
        #expect(shows(.thanksgivingUS, 2026, 11, 26))
        #expect(!shows(.thanksgivingUS, 2026, 11, 27))
        #expect(!shows(.thanksgivingUS, 2026, 11, 19))
        #expect(shows(.thanksgivingUS, 2027, 11, 25))
    }

    @Test func fixedDates() {
        #expect(shows(.christmas, 2026, 12, 25))
        #expect(!shows(.christmas, 2026, 12, 26))
        #expect(shows(.halloween, 2026, 10, 31))
        #expect(shows(.juneteenth, 2027, 6, 19))
        #expect(shows(.newYear, 2026, 12, 31))
        #expect(shows(.newYear, 2027, 1, 1))
        #expect(!shows(.newYear, 2027, 1, 2))
    }

    @Test func kwanzaaCrossesNewYear() {
        #expect(shows(.kwanzaa, 2026, 12, 26))
        #expect(shows(.kwanzaa, 2027, 1, 1))
        #expect(!shows(.kwanzaa, 2027, 1, 2))
    }

    @Test func leadDaysExtendTheStart() {
        #expect(shows(.hanukkah, 2026, 12, 2, lead: 2))
        #expect(!shows(.hanukkah, 2026, 12, 1, lead: 2))
        #expect(shows(.hanukkah, 2026, 12, 12, lead: 2))
        #expect(!shows(.hanukkah, 2026, 12, 13, lead: 2))
    }

    @Test func nextSpanFromInsideAndBefore() {
        let from = CivilDay(year: 2026, month: 12, day: 6)
        let span = Holidays.nextSpan(.hanukkah, from: from)
        #expect(span?.lowerBound == CivilDay(year: 2026, month: 12, day: 4))
        #expect(span?.upperBound == CivilDay(year: 2026, month: 12, day: 12))
        let next = Holidays.nextSpan(.hanukkah, from: CivilDay(year: 2026, month: 12, day: 13))
        #expect(next?.lowerBound == CivilDay(year: 2027, month: 12, day: 24))
    }

    @Test func upcomingIsSortedByDate() {
        let list = Holidays.upcoming(from: CivilDay(year: 2026, month: 11, day: 3))
        #expect(list.first?.holiday.id == .diwali)
        let ids = list.map(\.holiday.id)
        #expect(ids.firstIndex(of: .diwali)! < ids.firstIndex(of: .hanukkah)!)
        let starts = list.map(\.span.lowerBound)
        #expect(starts == starts.sorted())
        #expect(list.count == HolidayID.allCases.count)
    }

    @Test func everyHolidayHasANameAndOnlyTheRightOnesAreApproximate() {
        #expect(Holidays.all.count == HolidayID.allCases.count)
        #expect(Holidays.all.allSatisfy { !$0.name.isEmpty })
        let approx = Set(Holidays.all.filter(\.approximate).map(\.id))
        #expect(approx == [.ramadan, .eidAlFitr, .eidAlAdha, .diwali, .holi])
    }
}
