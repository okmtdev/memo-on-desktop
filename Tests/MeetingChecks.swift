import Foundation

@main
struct MeetingChecks {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let now = date(23, 14)
        let today = MeetingPeriod.today.interval(now: now, calendar: calendar)
        let upcoming = MeetingPeriod.upcoming.interval(now: now, calendar: calendar)
        assert(today.start == date(23) && today.end == date(24))
        assert(upcoming.start == date(24) && upcoming.end == date(31))
        func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarMeeting {
            CalendarMeeting(id: id, title: id, calendarTitle: "Fixture", start: start, end: end, allDay: allDay)
        }
        let early = event("morning", date(23, 9), date(23, 10))
        let late = event("afternoon", date(23, 15), date(23, 16))
        let allDay = event("all-day", date(23), date(24), allDay: true)
        let overnight = event("overnight", date(22, 23), date(23, 1))
        let endedAtMidnight = event("ended-yesterday", date(22, 23), date(23))
        let tomorrow = event("tomorrow", date(24, 9), date(24, 10))
        let lastDay = event("last-day", date(30, 23), date(31))
        let nextWeek = event("outside-week", date(31), date(31, 1))
        let multiDay = event("multi-day", date(23), date(25), allDay: true)
        let repeating1 = event("recurring-1", date(24, 10), date(24, 11))
        let repeating2 = event("recurring-2", date(25, 10), date(25, 11))
        let input = [late, tomorrow, nextWeek, early, allDay, overnight, endedAtMidnight, lastDay, early, repeating1, repeating2]
        let todays = MeetingList.meetings(input, period: .today, now: now, calendar: calendar)
        assert(todays.map(\.id) == ["all-day", "overnight", "morning", "afternoon"])
        let future = MeetingList.meetings(input, period: .upcoming, now: now, calendar: calendar)
        assert(future.map(\.id) == ["tomorrow", "recurring-1", "recurring-2", "last-day"])
        assert(multiDay.overlaps(today) && multiDay.overlaps(upcoming))
        assert(!endedAtMidnight.overlaps(today))
        assert(!nextWeek.overlaps(upcoming))
        let instant = event("instant", date(24), date(24))
        assert(!instant.overlaps(today) && instant.overlaps(upcoming))
        assert(MeetingList.webLink(URL(string: "https://meet.google.com/abc-defg-hij")) != nil)
        assert(MeetingList.webLink(URL(string: "file:///tmp/test")) == nil)
        assert(MeetingList.webLink(URL(string: "javascript:alert(1)")) == nil)
        // A week is seven local dates, even when daylight saving time ends.
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let beforeDST = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12))!
        let dstWeek = MeetingPeriod.upcoming.interval(now: beforeDST, calendar: calendar)
        assert(calendar.component(.day, from: dstWeek.start) == 1)
        assert(calendar.component(.day, from: dstWeek.end) == 8)
        assert(dstWeek.duration == 7 * 24 * 3600 + 3600)
        print("PASS: today/next-seven-days boundaries, all-day/overnight/multi-day events, recurring occurrences, sorting/deduplication, safe links, daylight saving")
    }
}
