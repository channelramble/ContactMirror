import XCTest
@testable import ContactMirrorCore

final class RecurrenceExpanderTests: XCTestCase {
    let ny = TimeZone(identifier: "America/New_York")!
    func d(_ s: String, _ tz: TimeZone) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }
    func fmt(_ dates: [Date], _ tz: TimeZone) -> [String] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH:mm"
        return dates.map(f.string)
    }
    func x(_ r: String, _ start: String, tz: TimeZone? = nil, until: String = "2030-01-01 00:00") -> [String]? {
        let z = tz ?? ny
        return RecurrenceExpander.expand(r, start: d(start, z), timeZone: z, allDay: false, until: d(until, z)).map { fmt($0, z) }
    }

    func testDailyCountAcrossDST() {
        // 9:00 wall clock is kept across the 14 March 2027 change.
        XCTAssertEqual(x("FREQ=DAILY;COUNT=3", "2027-03-13 09:00"), ["2027-03-13 09:00", "2027-03-14 09:00", "2027-03-15 09:00"])
    }
    func testWeeklyByDayInterval() {
        XCTAssertEqual(x("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=5", "2026-12-02 10:00"),
                       ["2026-12-02 10:00", "2026-12-14 10:00", "2026-12-16 10:00", "2026-12-28 10:00", "2026-12-30 10:00"])
    }
    func testWeeklyDefaultsToStartWeekday() {
        XCTAssertEqual(x("FREQ=WEEKLY;COUNT=3", "2026-11-27 10:00"), ["2026-11-27 10:00", "2026-12-04 10:00", "2026-12-11 10:00"])
    }
    func testMonthlyLastFridayAndSecondTuesday() {
        XCTAssertEqual(x("FREQ=MONTHLY;BYDAY=-1FR;COUNT=3", "2026-11-27 18:00"), ["2026-11-27 18:00", "2026-12-25 18:00", "2027-01-29 18:00"])
        XCTAssertEqual(x("FREQ=MONTHLY;BYDAY=2TU;COUNT=2", "2026-12-08 08:00"), ["2026-12-08 08:00", "2027-01-12 08:00"])
    }
    func testMonthly31stSkipsShortMonths() {
        XCTAssertEqual(x("FREQ=MONTHLY;COUNT=3", "2027-01-31 12:00"), ["2027-01-31 12:00", "2027-03-31 12:00", "2027-05-31 12:00"])
    }
    func testMonthlyLastDay() {
        XCTAssertEqual(x("FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=3", "2027-01-31 12:00"), ["2027-01-31 12:00", "2027-02-28 12:00", "2027-03-31 12:00"])
    }
    func testYearlyLeapDay() {
        XCTAssertEqual(x("FREQ=YEARLY;COUNT=2", "2028-02-29 09:00", until: "2033-01-01 00:00"), ["2028-02-29 09:00", "2032-02-29 09:00"])
    }
    func testUntilInclusive() {
        XCTAssertEqual(x("FREQ=DAILY;UNTIL=20261203T140000Z", "2026-12-01 09:00"), ["2026-12-01 09:00", "2026-12-02 09:00", "2026-12-03 09:00"])
        XCTAssertEqual(x("FREQ=DAILY;UNTIL=20261202", "2026-12-01 09:00"), ["2026-12-01 09:00", "2026-12-02 09:00"])
    }
    func testWeekdaysDaily() {
        XCTAssertEqual(x("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;COUNT=3", "2026-12-04 07:00"), ["2026-12-04 07:00", "2026-12-07 07:00", "2026-12-08 07:00"])
    }
    func testUnsupportedReturnsNil() {
        XCTAssertNil(x("FREQ=HOURLY;COUNT=3", "2026-12-04 07:00"))
        XCTAssertNil(x("FREQ=YEARLY;BYWEEKNO=20", "2026-12-04 07:00"))
    }
    func testOpenEndedStopsAtSearchEnd() {
        XCTAssertEqual(x("FREQ=WEEKLY", "2026-12-01 09:00", until: "2026-12-20 00:00")?.count, 3)
    }
}
