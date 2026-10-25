import Foundation

@main
struct WorkspaceChecks {
    @MainActor
    static func main() throws {
        let suite = "MemoOnDesktop.WorkspaceChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = SavedTaskView(name: "締め切り確認", section: .upcoming, sort: .priority, priority: .high,
            kind: .work, due: .any, showTodayMeetings: false, showUpcomingMeetings: true)
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "memo-on-desktop.savedViews.v1")
        let oldConfig = try JSONDecoder().decode(ViewConfiguration.self, from: Data(#"{"status":"未完了","sort":"期限順","search":"既存の検索","calendar":"今日","includeAllDay":false}"#.utf8))
        assert(oldConfig.sortRules == TaskSortRule.defaults && oldConfig.search == "既存の検索" && oldConfig.calendar == .today && !oldConfig.includeAllDay)
        let oldPriority = try JSONDecoder().decode(ViewConfiguration.self, from: Data(#"{"sort":"優先度順"}"#.utf8))
        assert(oldPriority.sortRules == [TaskSortRule(.priority), TaskSortRule(.deadline)])
        let oldCompleted = try JSONDecoder().decode(ViewConfiguration.self, from: Data(#"{"sort":"完了が新しい順"}"#.utf8))
        assert(oldCompleted.sortRules == [TaskSortRule(.completed)])
        let store = SavedViewsStore(defaults: defaults)
        assert(store.configuration.sortRules == oldPriority.sortRules)
        assert(store.views.count == 1 && store.selectedID == legacy.id)
        assert(store.configuration.due == .upcoming && store.configuration.calendar == .upcoming)
        assert(store.configuration.priority == .high && !store.hasChanges)
        store.configuration.calendar = .week
        store.configuration.includeAllDay = false
        store.configuration.status = .all
        store.configuration.search = "確認"
        assert(store.hasChanges)
        store.saveAs("新しいビュー")
        let copyID = store.selectedID
        assert(store.views.count == 2 && !store.hasChanges)
        store.select(legacy.id)
        assert(store.hasChanges && store.configuration.calendar == .week)
        store.discardChanges()
        assert(store.configuration.calendar == .upcoming && !store.hasChanges)
        store.select(copyID)
        store.configuration.hideEndedMeetings = true
        store.save()
        store.rename("仕事の計画")
        var restored = SavedViewsStore(defaults: defaults)
        assert(restored.selected.name == "仕事の計画" && restored.configuration.hideEndedMeetings && !restored.hasChanges)
        restored.configuration.sortRules = [TaskSortRule(.completed), TaskSortRule(.priority, direction: .descending)]
        restored = SavedViewsStore(defaults: defaults)
        assert(restored.hasChanges && restored.configuration.sortRules == [TaskSortRule(.completed), TaskSortRule(.priority, direction: .descending)])
        restored.save()
        restored = SavedViewsStore(defaults: defaults)
        assert(!restored.hasChanges && restored.configuration.sortRules.count == 2 && restored.configuration.sortRules[1].direction == .descending)
        restored.select(legacy.id)
        assert(restored.configuration.sortRules == oldPriority.sortRules)
        restored.select(copyID)
        restored.delete(copyID)
        assert(restored.selectedID == legacy.id)
        restored.delete(legacy.id)
        assert(restored.views.count == 1 && restored.configuration == ViewConfiguration())
        // Invalid persisted data must not be silently replaced.
        let invalid = Data("invalid".utf8)
        defaults.set(invalid, forKey: "memo-on-desktop.views.v2")
        let broken = SavedViewsStore(defaults: defaults)
        assert(broken.storageError != nil)
        broken.saveAs("should not overwrite")
        assert(defaults.data(forKey: "memo-on-desktop.views.v2") == invalid)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ day: Int, _ hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        let now = date(25, 12)
        let today = TaskDay(now, timeZone: calendar.timeZone)
        func task(_ title: String, created: Date, completed: Date? = nil, kind: TaskKind = .work, due: TaskDay? = nil) -> TodoItem {
            TodoItem(title: title, kind: kind, isComplete: completed != nil, completedAt: completed, createdAt: created, dueDate: due)
        }
        let first = task("確認1", created: date(18), completed: date(19)) // period boundary, duration 1 day
        let second = task("確認2", created: date(23), completed: now, kind: .personal, due: today) // 2.5 days
        let previous = task("前期間", created: date(10), completed: date(18, 23))
        let future = task("未来", created: now, completed: date(26))
        let open = task("長いタスク", created: date(1), due: TaskDay(year: 2026, month: 10, day: 24))
        var recurring = task("未来の回", created: date(1), due: today.adding(days: 7))
        recurring.recurringTaskID = UUID(); recurring.occurrenceDate = today.adding(days: 7)
        var unknown = task("日時不明", created: date(1)); unknown.isComplete = true
        let invalidTime = task("時刻不整合", created: date(25), completed: date(24))
        let input = [first, second, previous, future, open, recurring, unknown, invalidTime]
        let review = TaskReview(items: input, period: .week, now: now, calendar: calendar)
        assert(review.start == date(19) && review.previousStart == date(12))
        assert(review.completed.count == 3 && review.previousCompleted.count == 1)
        assert(review.days.count == 7 && review.days.first!.completed == 1 && review.days.last!.completed == 1)
        assert(review.median == 1.75 * 86400 && review.durations.count == 2 && review.p90 == 2.5 * 86400)
        assert(review.unknownCompletionCount == 1 && review.invalidDurationCount == 1)
        assert(review.overdue.map(\.id) == [open.id] && review.aging.map(\.id) == [open.id])
        assert(review.attentionItems.first?.id == open.id)
        assert(review.futureRecurringCount == 1 && review.open.count == 1)
        assert(review.onTimeCount == 1 && review.onTimeRate == 1)
        assert(review.durationBuckets.reduce(0) { $0 + $1.count } == 2)
        let hidden = TaskReview(items: input, period: .week, now: now, hidePersonal: true, includeRecurring: false, calendar: calendar)
        assert(hidden.completed.count == 2 && hidden.median == 86400 && hidden.futureRecurringCount == 0)
        let empty = TaskReview(items: [], period: .month, now: now, calendar: calendar)
        assert(empty.median == nil && empty.onTimeRate == nil && empty.dailyAverage == 0 && empty.days.count == 30)
        assert(TaskReview.percentile([0, 10, 20, 30], fraction: 0.9) == 27)
        var config = ViewConfiguration()
        config.status = .all; config.search = "確認"; config.sortRules = [TaskSortRule(.completed)]
        assert(config.items(input, today: today, hidePersonal: false).map(\.id) == [second.id, first.id])
        assert(config.items(input, today: today, hidePersonal: true).map(\.id) == [first.id])
        config = ViewConfiguration(); config.due = .overdue
        assert(config.items(input, today: today, hidePersonal: false).map(\.id) == [open.id])
        config.status = .completed; config.due = .today
        assert(config.items(input, today: today, hidePersonal: false).map(\.id) == [second.id])
        // The second/third condition must decide ties, without an implicit priority rule interfering.
        var earlyLow = task("early-low", created: date(1), due: today.adding(days: -1)); earlyLow.priority = .low
        var sameOldLow = task("same-old-low", created: date(1), due: today); sameOldLow.priority = .low
        var sameNewHigh = task("same-new-high", created: date(2), due: today); sameNewHigh.priority = .high
        var sameOldHigh = task("same-old-high", created: date(1), due: today); sameOldHigh.priority = .high
        var noDateHigh = task("no-date-high", created: date(3)); noDateHigh.priority = .high
        let noDateLow = task("no-date-middle", created: date(4))
        let sortable = [noDateLow, sameNewHigh, earlyLow, noDateHigh, sameOldLow, sameOldHigh]
        func sortedTitles(_ rules: [TaskSortRule]) -> [String] {
            TaskList.customized(sortable, sortRules: rules, priority: nil, kind: nil, due: .any, today: today).map(\.title)
        }
        assert(sortedTitles([TaskSortRule(.deadline), TaskSortRule(.priority), TaskSortRule(.created, direction: .ascending)]) ==
            ["early-low", "same-old-high", "same-new-high", "same-old-low", "no-date-high", "no-date-middle"])
        let creationSecond = sortedTitles([TaskSortRule(.deadline), TaskSortRule(.created, direction: .ascending), TaskSortRule(.priority, direction: .descending)])
        assert(creationSecond == ["early-low", "same-old-low", "same-old-high", "same-new-high", "no-date-high", "no-date-middle"])
        assert(sortedTitles([TaskSortRule(.priority, direction: .descending), TaskSortRule(.deadline)]) ==
            ["early-low", "same-old-low", "no-date-middle", "same-new-high", "same-old-high", "no-date-high"])
        assert(sortedTitles([TaskSortRule(.deadline, direction: .descending), TaskSortRule(.priority)]).suffix(2) == ["no-date-high", "no-date-middle"])
        assert(sortedTitles([TaskSortRule(.created, direction: .ascending)]).last == "no-date-middle")
        let completedAscending = TaskList.customized([second, first, unknown], sortRules: [TaskSortRule(.completed, direction: .ascending)], priority: nil, kind: nil, due: .any, today: today)
        assert(completedAscending.map(\.id) == [first.id, second.id, unknown.id])
        assert(TaskSortRule.normalized([]) == TaskSortRule.defaults)
        assert(TaskSortRule.normalized([TaskSortRule(.priority), TaskSortRule(.priority, direction: .descending)]).count == 1)
        var multiConfig = ViewConfiguration()
        multiConfig.sortRules = [TaskSortRule(.created, direction: .ascending), TaskSortRule(.deadline, direction: .descending)]
        let roundTripConfig = try JSONDecoder().decode(ViewConfiguration.self, from: JSONEncoder().encode(multiConfig))
        assert(roundTripConfig == multiConfig)

        // Long-open attention is independent of the chosen report period and of deadline presence.
        func aged(_ title: String, days: Double) -> TodoItem { task(title, created: now.addingTimeInterval(-days * 86400)) }
        let belowSeven = aged("not yet", days: 7 - 1.0 / 86400)
        let seven = aged("seven", days: 7), fourteen = aged("fourteen", days: 14), thirty = aged("thirty", days: 30)
        var personalOld = aged("private-old", days: 50); personalOld.kind = .personal
        var futureRepeat = aged("future-repeat", days: 60)
        futureRepeat.recurringTaskID = UUID(); futureRepeat.occurrenceDate = today.adding(days: 1)
        var doneOld = aged("done-old", days: 70); doneOld.isComplete = true; doneOld.completedAt = now
        let oldTasks = [belowSeven, seven, fourteen, thirty, personalOld, futureRepeat, doneOld]
        let longOpen = TaskReview(items: oldTasks, period: .week, now: now, calendar: calendar)
        assert(longOpen.aging.map(\.title) == ["private-old", "thirty", "fourteen", "seven"])
        assert(longOpen.agingCount(.watch) == 1 && longOpen.agingCount(.elevated) == 1 && longOpen.agingCount(.critical) == 2)
        assert(OpenTaskAttention.level(days: longOpen.openDays(belowSeven)) == nil)
        assert(longOpen.openDays(thirty) == 30)
        let privateHidden = TaskReview(items: oldTasks, period: .quarter, now: now, hidePersonal: true, calendar: calendar)
        assert(privateHidden.aging.map(\.title) == ["thirty", "fourteen", "seven"] && privateHidden.agingCount(.critical) == 1)
        assert(TaskReview(items: oldTasks, period: .month, now: now, calendar: calendar).aging.map(\.id) == longOpen.aging.map(\.id))
        assert(OpenTaskAttention.level(days: 13) == .watch && OpenTaskAttention.level(days: 29) == .elevated)
        assert(MeetingPeriod.week.interval(now: now, calendar: calendar).start == date(25))
        assert(MeetingPeriod.week.interval(now: now, calendar: calendar).end == date(32))
        // Calendar-day aggregation must survive a 25-hour DST day.
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstNow = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        let dst = TaskReview(items: [], period: .week, now: dstNow, calendar: calendar)
        assert(dst.days.count == 7 && Set(dst.days.map(\.date)).count == 7)
        assert(dst.days.last!.date.timeIntervalSince(dst.start) == 6 * 86400 + 3600)
        print("PASS: multi-key sorting and directions, nil-date ordering, single-sort migration, long-open attention boundaries/privacy, view migration, save/copy/rename/delete, per-view drafts, relaunch, corrupt-data protection, filters, calendar range, review boundaries, missing/invalid timestamps, median/P90, privacy, recurring backlog, empty data, DST")
    }
}
