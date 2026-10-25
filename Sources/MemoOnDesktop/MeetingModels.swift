import Foundation

struct MeetingCalendar: Identifiable, Sendable {
    var id: String
    var title: String
    var account: String
    var primary = false
    var timeZone: String? = nil
}

enum MeetingPeriod: String, Sendable {
    case today, upcoming, week

    var title: String { self == .today ? "今日の予定" : (self == .week ? "7日間の予定" : "今後の予定") }
    var subtitle: String { self == .today ? "今日の予定" : (self == .week ? "今日から7日間" : "明日から7日間") }

    func interval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start = self == .upcoming ? calendar.date(byAdding: .day, value: 1, to: today)! : today
        let end = calendar.date(byAdding: .day, value: self == .today ? 1 : 7, to: start)!
        return DateInterval(start: start, end: end)
    }
}

struct CalendarMeeting: Identifiable, Sendable {
    var id: String
    var title: String
    var calendarTitle: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
    var link: URL?

    func overlaps(_ interval: DateInterval) -> Bool {
        // Calendar end dates are exclusive, including for multi-day all-day events.
        if end <= start { return start >= interval.start && start < interval.end }
        return start < interval.end && end > interval.start
    }
}

enum MeetingList {
    static func meetings(_ meetings: [CalendarMeeting], period: MeetingPeriod, now: Date, calendar: Calendar = .current) -> [CalendarMeeting] {
        let interval = period.interval(now: now, calendar: calendar)
        var seen: Set<String> = []
        return meetings.filter { $0.overlaps(interval) && seen.insert($0.id).inserted }.sorted {
            let left = max($0.start, interval.start)
            let right = max($1.start, interval.start)
            let leftDay = calendar.startOfDay(for: left)
            let rightDay = calendar.startOfDay(for: right)
            if leftDay != rightDay { return leftDay < rightDay }
            if $0.allDay != $1.allDay { return $0.allDay }
            if left != right { return left < right }
            return $0.id < $1.id
        }
    }

    static func webLink(_ url: URL?) -> URL? {
        guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
