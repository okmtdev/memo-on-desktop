import Foundation

@main
struct RecurringChecks {
    @MainActor
    static func main() throws {
        let friday = TaskDay(year: 2026, month: 10, day: 23)
        let weekly = RecurrenceRule(frequency: .weekly, weekdays: [.monday, .friday], monthDay: 1)
        assert(weekly.first(onOrAfter: friday) == friday)
        assert(weekly.first(onOrAfter: friday.adding(days: 1)) == friday.adding(days: 3))
        let sunday = RecurrenceRule(frequency: .weekly, weekdays: [.sunday], monthDay: 1)
        assert(sunday.first(onOrAfter: TaskDay(year: 2026, month: 12, day: 31)) == TaskDay(year: 2027, month: 1, day: 3))
        assert(!RecurrenceRule(frequency: .weekly, weekdays: [], monthDay: 1).isValid)
        assert(!RecurrenceRule(frequency: .monthly, weekdays: [], monthDay: 32).isValid)
        let monthly = RecurrenceRule(frequency: .monthly, weekdays: [], monthDay: 31)
        let jan31 = TaskDay(year: 2027, month: 1, day: 31)
        let feb28 = TaskDay(year: 2027, month: 2, day: 28)
        assert(monthly.first(onOrAfter: jan31) == jan31)
        assert(monthly.first(onOrAfter: jan31.adding(days: 1)) == feb28)
        assert(monthly.first(onOrAfter: feb28.adding(days: 1)) == TaskDay(year: 2027, month: 3, day: 31))
        assert(monthly.first(onOrAfter: TaskDay(year: 2028, month: 2, day: 1)) == TaskDay(year: 2028, month: 2, day: 29))

        let template = RecurringTask(title: "週次レポート", kind: .work, priority: .high,
            url: URL(string: "https://example.com/report"), rule: weekly, startDate: friday, nextDate: friday)
        var state = TaskSnapshot(items: [], recurringTasks: [template])
        assert(RecurringTaskGenerator.materialize(&state, today: friday) == 9)
        assert(Set(state.items.compactMap(\.dueDate)).count == 9)
        assert(state.items.allSatisfy { $0.priority == .high && $0.url == template.url && $0.recurringTaskID == template.id })
        assert(state.items.allSatisfy { $0.dueDate! >= friday && $0.dueDate! <= friday.adding(days: 30) })
        let originalIDs = Set(state.items.map(\.id))
        state = try JSONDecoder().decode(TaskSnapshot.self, from: JSONEncoder().encode(state))
        assert(RecurringTaskGenerator.materialize(&state, today: friday) == 0)
        assert(Set(state.items.map(\.id)) == originalIDs)
        // Deleted, completed, or rescheduled occurrences must not reappear.
        state.items.remove(at: 0)
        state.items[0].isComplete = true
        state.items[1].dueDate = friday.adding(days: 100)
        assert(RecurringTaskGenerator.materialize(&state, today: friday) == 0)
        let beforeCatchup = state.items.count
        assert(RecurringTaskGenerator.materialize(&state, today: friday.adding(days: 60)) > 0)
        assert(state.items.count > beforeCatchup)
        assert(state.items.contains { $0.occurrenceDate == friday.adding(days: 31) })
        var future = TaskSnapshot(items: [], recurringTasks: [RecurringTask(title: "将来開始", kind: .work, priority: .middle,
            rule: weekly, startDate: friday.adding(days: 100), nextDate: weekly.first(onOrAfter: friday.adding(days: 100))!)])
        assert(RecurringTaskGenerator.materialize(&future, today: friday) == 0)

        // Use a disposable defaults suite; never read or mutate the user's tasks.
        let suite = "MemoOnDesktop.RecurringChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = Data(#"[{"id":"11111111-1111-1111-1111-111111111111","title":"既存タスク","kind":"仕事","isComplete":false,"createdAt":0}]"#.utf8)
        defaults.set(legacy, forKey: "memo-on-desktop.tasks.v1")
        let today = TaskDay(Date())
        let store = TaskStore(defaults: defaults)
        assert(store.items.count == 1 && store.items[0].priority == .middle)
        assert(store.add(title: "定期テスト", kind: .personal, priority: .low, recurrence: weekly, today: today))
        assert(defaults.data(forKey: "memo-on-desktop.tasks.v1") == legacy)
        let savedIDs = Set(store.items.map(\.id))
        let restored = TaskStore(defaults: defaults)
        assert(Set(restored.items.map(\.id)) == savedIDs && restored.recurringTasks.count == 1)
        let ruleID = restored.recurringTasks[0].id
        let occurrence = restored.items.first { $0.recurringTaskID == ruleID }!
        restored.toggle(occurrence)
        restored.setRecurringPriority(ruleID, priority: .high)
        assert(restored.items.first { $0.id == occurrence.id }!.priority == .low)
        assert(restored.items.filter { $0.recurringTaskID == ruleID && !$0.isComplete }.allSatisfy { $0.priority == .high })
        let deleted = restored.items.first { $0.recurringTaskID == ruleID && !$0.isComplete }!
        restored.delete(deleted)
        restored.generateRecurringTasks(today: today)
        assert(!restored.items.contains { $0.recurringTaskID == ruleID && $0.occurrenceDate == deleted.occurrenceDate })
        restored.setRecurringActive(ruleID, active: false, today: today)
        let beforePause = Set(restored.items.map(\.id))
        let resumedDay = today.adding(days: 90)
        restored.generateRecurringTasks(today: resumedDay)
        assert(Set(restored.items.map(\.id)) == beforePause)
        restored.setRecurringActive(ruleID, active: true, today: resumedDay)
        let newItems = restored.items.filter { !beforePause.contains($0.id) }
        assert(!newItems.isEmpty && newItems.allSatisfy { $0.occurrenceDate! >= resumedDay })
        let beforeRemoval = Set(restored.items.map(\.id))
        restored.removeRecurring(ruleID)
        assert(restored.recurringTasks.isEmpty && Set(restored.items.map(\.id)) == beforeRemoval)
        let final = TaskStore(defaults: defaults)
        assert(final.recurringTasks.isEmpty && Set(final.items.map(\.id)) == beforeRemoval)
        final.draftPriority = .high
        final.draftRecurrence.frequency = .weekly
        final.resetDraft()
        assert(final.draftPriority == .middle && final.draftRecurrence.frequency == .none)
        let corrupt = Data("broken".utf8)
        defaults.set(corrupt, forKey: "memo-on-desktop.state.v2")
        let blocked = TaskStore(defaults: defaults)
        assert(blocked.storageError != nil && !blocked.add(title: "上書き防止", kind: .work))
        assert(defaults.data(forKey: "memo-on-desktop.state.v2") == corrupt)
        print("PASS: weekly/monthly schedules, leap years/month-end, rolling horizon, restart deduplication, catch-up, legacy migration, priorities, pause/resume, rule removal, corrupt-data protection")
    }
}
