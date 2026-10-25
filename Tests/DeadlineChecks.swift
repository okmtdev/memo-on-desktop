import Foundation

@main
struct DeadlineChecks {
    static func main() throws {
        let today = TaskDay(year: 2026, month: 10, day: 23)
        let yesterday = TaskDay(year: 2026, month: 10, day: 22)
        let tomorrow = TaskDay(year: 2026, month: 10, day: 24)
        let oldData = Data(#"{"id":"11111111-1111-1111-1111-111111111111","title":"既存タスク","kind":"仕事","isComplete":false,"createdAt":0}"#.utf8)
        let old = try JSONDecoder().decode(TodoItem.self, from: oldData)
        assert(old.dueDate == nil && old.url == nil && old.priority == .middle)
        let task = TodoItem(title: "締め切り付き", kind: .work, dueDate: tomorrow, priority: .high)
        let restored = try JSONDecoder().decode(TodoItem.self, from: JSONEncoder().encode(task))
        assert(restored.dueDate == tomorrow && restored.title == task.title && restored.priority == .high)
        // Date-only storage does not become the previous/next date in another zone.
        for zone in ["Asia/Tokyo", "America/Los_Angeles", "Pacific/Auckland"] {
            let timezone = TimeZone(identifier: zone)!
            assert(TaskDay(restored.dueDate!.date(timeZone: timezone), timeZone: timezone) == tomorrow)
        }
        assert(TaskDay(year: 2026, month: 12, day: 31).adding(days: 1) == TaskDay(year: 2027, month: 1, day: 1))
        assert(TaskDay(year: 2028, month: 2, day: 28).adding(days: 1) == TaskDay(year: 2028, month: 2, day: 29))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let lateToday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 23, minute: 59))!
        let earlyTomorrow = calendar.date(byAdding: .minute, value: 1, to: lateToday)!
        assert(TaskDay(lateToday, timeZone: calendar.timeZone) == today)
        assert(TaskDay(earlyTomorrow, timeZone: calendar.timeZone) == tomorrow)
        assert(today.label(relativeTo: today) == "今日が締め切り")
        assert(today.label(relativeTo: tomorrow).contains("期限超過"))
        let overdue = TodoItem(title: "期限超過", kind: .work, dueDate: yesterday)
        let dueToday = TodoItem(title: "今日", kind: .personal, dueDate: today)
        let upcoming = TodoItem(title: "今後", kind: .work, dueDate: tomorrow)
        let undated = TodoItem(title: "期限なし", kind: .work)
        var completed = TodoItem(title: "完了", kind: .work, dueDate: yesterday)
        completed.isComplete = true
        let all = [undated, upcoming, dueToday, overdue, completed]
        func titles(_ section: AppSection, hidden: Bool = false) -> [String] {
            TaskList.items(all, in: section, today: today, hidePersonal: hidden).map(\.title)
        }
        assert(titles(.all) == ["期限超過", "今日", "今後", "期限なし"])
        assert(titles(.today) == ["期限超過", "今日", "今後", "期限なし"])
        assert(titles(.upcoming) == ["今後"])
        assert(titles(.undated) == ["期限なし"])
        assert(titles(.completed) == ["完了"])
        assert(titles(.today, hidden: true) == ["期限超過", "今後", "期限なし"])
        assert(TaskList.items(all, in: .today, today: tomorrow, hidePersonal: false).map(\.title) == ["期限超過", "今日", "今後", "期限なし"])
        let priorities = [TaskPriority.low, .middle, .high].map { TodoItem(title: $0.rawValue, kind: .work, dueDate: today, priority: $0) }
        assert(TaskList.items(priorities, in: .today, today: today, hidePersonal: false).map(\.priority) == [.high, .middle, .low])
        let earlierLow = TodoItem(title: "昨日のLow", kind: .work, dueDate: yesterday, priority: .low)
        assert(TaskList.items(priorities + [earlierLow], in: .today, today: today, hidePersonal: false).first?.id == earlierLow.id)
        let futureHigh = TodoItem(title: "明日のHigh", kind: .work, dueDate: tomorrow, priority: .high)
        let todayLow = TodoItem(title: "今日のLow", kind: .work, dueDate: today, priority: .low)
        let undatedHigh = TodoItem(title: "期限なしHigh", kind: .work, priority: .high)
        let mixed = [undatedHigh, futureHigh, todayLow] + priorities
        let sortedMixed = TaskList.items(mixed, in: .today, today: today, hidePersonal: false)
        assert(sortedMixed.prefix(4).map(\.priority) == [.high, .middle, .low, .low])
        assert(sortedMixed.suffix(2).map(\.id) == [futureHigh.id, undatedHigh.id])
        let groups = TodayTaskGroup.allCases.map { group in all.filter { !$0.isComplete && group.contains($0, today: today) }.map(\.title) }
        assert(groups == [["期限超過"], ["今日"], ["今後"], ["期限なし"]])
        print("PASS: legacy task decoding, due-date persistence/timezones, day boundaries/leap years, deadline/priority sorting, today groups including future tasks, section filters, privacy")
    }
}
