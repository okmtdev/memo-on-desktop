import Foundation

@main
struct TaskEditingChecks {
    @MainActor
    static func main() throws {
        let suite = "MemoOnDesktop.TaskEditingChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskStore(defaults: defaults)
        let today = TaskDay(Date())
        assert(store.add(title: "最初のタイトル", kind: .work, dueDate: today, priority: .high))
        let original = store.items[0]
        store.beginEditing(original)
        assert(store.rename(original.id, title: "  修正後  "))
        assert(store.items[0].title == "修正後" && store.editDrafts[original.id]?.title == "修正後")
        assert(!store.rename(original.id, title: " \n "))
        assert(store.items[0].title == "修正後")
        // Closing/reopening the editor preserves unsaved input, without applying it.
        store.editDrafts[original.id]?.title = "編集中"
        store.beginEditing(store.items[0])
        assert(store.editDrafts[original.id]?.title == "編集中" && store.items[0].title == "修正後")
        store.setDueDate(today.adding(days: 1), for: original)
        store.setPriority(.low, for: original)
        assert(store.editDrafts[original.id]?.dueDate == today.adding(days: 1))
        assert(store.editDrafts[original.id]?.priority == .low)
        // A deliberately changed draft value is retained when the row changes.
        store.editDrafts[original.id]?.priority = .middle
        store.setPriority(.high, for: original)
        assert(store.editDrafts[original.id]?.priority == .middle)
        let finished = Date(timeIntervalSince1970: 1_800_000_000)
        store.toggle(original, at: finished)
        assert(store.items[0].isComplete && store.items[0].completedAt == finished)
        let url = URL(string: "https://example.com/request")!
        assert(store.update(original.id, title: "  内容を編集  ", kind: .personal, url: url, dueDate: nil, priority: .middle))
        let edited = store.items[0]
        assert(edited.title == "内容を編集" && edited.kind == .personal && edited.url == url && edited.dueDate == nil && edited.priority == .middle)
        assert(edited.id == original.id && edited.createdAt == original.createdAt && edited.completedAt == finished && edited.isComplete)
        assert(store.editDrafts[original.id] == nil)
        assert(!store.update(original.id, title: "", kind: .work, url: nil, dueDate: today, priority: .high))
        let restored = TaskStore(defaults: defaults)
        assert(restored.items[0].title == edited.title && restored.items[0].completedAt == finished)
        assert(restored.editDrafts.isEmpty)
        restored.toggle(restored.items[0], at: finished.addingTimeInterval(60))
        assert(!restored.items[0].isComplete && restored.items[0].completedAt == nil)
        restored.toggle(restored.items[0], at: finished.addingTimeInterval(120))
        assert(restored.items[0].completedAt == finished.addingTimeInterval(120))

        // Completed ordering must ignore deadlines, priorities and creation order.
        let legacyData = Data(#"{"id":"11111111-1111-1111-1111-111111111111","title":"以前の完了","kind":"仕事","isComplete":true,"createdAt":0}"#.utf8)
        let legacy = try JSONDecoder().decode(TodoItem.self, from: legacyData)
        assert(legacy.isComplete && legacy.completedAt == nil)
        var first = TodoItem(title: "先に完了", kind: .work, dueDate: today.adding(days: -10), priority: .high)
        first.isComplete = true
        first.completedAt = finished
        var last = TodoItem(title: "最後に完了", kind: .work, dueDate: today.adding(days: 100), priority: .low)
        last.isComplete = true
        last.completedAt = finished.addingTimeInterval(300)
        assert(TaskList.items([legacy, first, last], in: .completed, today: today, hidePersonal: false).map(\.title) == ["最後に完了", "先に完了", "以前の完了"])

        // Editing one recurring occurrence never rewrites the rule or other occurrences.
        let weekly = RecurrenceRule(frequency: .weekly, weekdays: [today.weekday], monthDay: 1)
        assert(restored.add(title: "定期", kind: .work, priority: .low, recurrence: weekly, today: today))
        let template = restored.recurringTasks[0]
        let occurrence = restored.items.first { $0.recurringTaskID == template.id }!
        assert(restored.update(occurrence.id, title: "この回だけ", kind: .personal, url: url, dueDate: nil, priority: .high))
        let changed = restored.items.first { $0.id == occurrence.id }!
        assert(changed.recurringTaskID == template.id && changed.occurrenceDate == occurrence.occurrenceDate)
        assert(restored.recurringTasks[0].title == "定期" && restored.recurringTasks[0].priority == .low)
        assert(restored.items.filter { $0.recurringTaskID == template.id && $0.id != occurrence.id }.allSatisfy { $0.title == "定期" && $0.priority == .low })
        let count = restored.items.count
        restored.generateRecurringTasks(today: today)
        assert(restored.items.count == count)
        print("PASS: inline rename, blank-title rejection, full edits preserving identity/completion, drafts, completion timestamps/reopen/recomplete, completion ordering, legacy completion data, per-occurrence edits, persistence")
    }
}
