import Combine
import Foundation

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = []
    @Published private(set) var recurringTasks: [RecurringTask] = []
    @Published private(set) var storageError: String?
    @Published var draftTitle = ""
    @Published var draftKind: TaskKind = .work
    @Published var draftURL = ""
    @Published var draftDueDate: TaskDay?
    @Published var draftPriority: TaskPriority = .middle
    @Published var draftRecurrence = RecurrenceDraft()
    @Published var editDrafts: [UUID: TaskEditDraft] = [:]

    private let storageKey = "memo-on-desktop.state.v2"
    private let legacyStorageKey = "memo-on-desktop.tasks.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: "MemoOnDesktop") ?? .standard) {
        self.defaults = defaults
        load()
        generateRecurringTasks()
    }

    @discardableResult
    func add(title: String, kind: TaskKind, url: URL? = nil, dueDate: TaskDay? = nil,
             priority: TaskPriority = .middle, recurrence: RecurrenceRule? = nil, today: TaskDay = TaskDay(Date())) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, storageError == nil else { return false }
        if let recurrence {
            guard let first = recurrence.first(onOrAfter: max(dueDate ?? today, today)) else { return false }
            recurringTasks.append(RecurringTask(title: title, kind: kind, priority: priority, url: url,
                rule: recurrence, startDate: dueDate ?? today, nextDate: first))
            generateRecurringTasks(today: today)
        } else {
            items.insert(TodoItem(title: title, kind: kind, url: url, dueDate: dueDate, priority: priority), at: 0)
        }
        save()
        return true
    }

    func resetDraft() {
        draftTitle = ""
        draftKind = .work
        draftURL = ""
        draftDueDate = nil
        draftPriority = .middle
        draftRecurrence = RecurrenceDraft()
    }

    func toggle(_ item: TodoItem, at completionDate: Date = Date()) {
        guard storageError == nil, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isComplete.toggle()
        items[index].completedAt = items[index].isComplete ? completionDate : nil
        save()
    }

    func beginEditing(_ item: TodoItem) {
        if editDrafts[item.id] == nil { editDrafts[item.id] = TaskEditDraft(item) }
    }

    @discardableResult
    func rename(_ id: UUID, title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storageError == nil, !title.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[index].title != title else { return true }
        if editDrafts[id]?.title == items[index].title { editDrafts[id]?.title = title }
        items[index].title = title
        save()
        return storageError == nil
    }

    @discardableResult
    func update(_ id: UUID, title: String, kind: TaskKind, url: URL?, dueDate: TaskDay?, priority: TaskPriority) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storageError == nil, !title.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].title = title
        items[index].kind = kind
        items[index].url = url
        items[index].dueDate = dueDate
        items[index].priority = priority
        save()
        guard storageError == nil else { return false }
        editDrafts.removeValue(forKey: id)
        return true
    }

    func setDueDate(_ dueDate: TaskDay?, for item: TodoItem) {
        guard storageError == nil, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if editDrafts[item.id]?.dueDate == items[index].dueDate { editDrafts[item.id]?.dueDate = dueDate }
        items[index].dueDate = dueDate
        save()
    }

    func setPriority(_ priority: TaskPriority, for item: TodoItem) {
        guard storageError == nil, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if editDrafts[item.id]?.priority == items[index].priority { editDrafts[item.id]?.priority = priority }
        items[index].priority = priority
        save()
    }

    func delete(_ item: TodoItem) {
        guard storageError == nil else { return }
        items.removeAll { $0.id == item.id }
        editDrafts.removeValue(forKey: item.id)
        save()
    }

    func setRecurringActive(_ id: UUID, active: Bool, today: TaskDay = TaskDay(Date())) {
        guard storageError == nil, let index = recurringTasks.firstIndex(where: { $0.id == id }) else { return }
        recurringTasks[index].isActive = active
        if active, recurringTasks[index].nextDate < today,
           let next = recurringTasks[index].rule.first(onOrAfter: max(today, recurringTasks[index].startDate)) {
            recurringTasks[index].nextDate = next
        }
        generateRecurringTasks(today: today)
        save()
    }

    func setRecurringPriority(_ id: UUID, priority: TaskPriority) {
        guard storageError == nil, let index = recurringTasks.firstIndex(where: { $0.id == id }) else { return }
        recurringTasks[index].priority = priority
        for itemIndex in items.indices where items[itemIndex].recurringTaskID == id && !items[itemIndex].isComplete {
            let itemID = items[itemIndex].id
            if editDrafts[itemID]?.priority == items[itemIndex].priority { editDrafts[itemID]?.priority = priority }
            items[itemIndex].priority = priority
        }
        save()
    }

    func removeRecurring(_ id: UUID) {
        guard storageError == nil else { return }
        recurringTasks.removeAll { $0.id == id }
        save()
    }

    func generateRecurringTasks(today: TaskDay = TaskDay(Date())) {
        guard storageError == nil, !recurringTasks.isEmpty else { return }
        var snapshot = TaskSnapshot(items: items, recurringTasks: recurringTasks)
        let previousCursor = snapshot.recurringTasks.map(\.nextDate)
        let generated = RecurringTaskGenerator.materialize(&snapshot, today: today)
        if generated > 0 || previousCursor != snapshot.recurringTasks.map(\.nextDate) {
            items = snapshot.items
            recurringTasks = snapshot.recurringTasks
            save()
        }
    }

    private func load() {
        do {
            if let data = defaults.data(forKey: storageKey) {
                let state = try JSONDecoder().decode(TaskSnapshot.self, from: data)
                items = state.items
                recurringTasks = state.recurringTasks
            } else if let data = defaults.data(forKey: legacyStorageKey) {
                items = try JSONDecoder().decode([TodoItem].self, from: data)
            }
        } catch {
            storageError = "保存済みタスクを読み込めませんでした。元のデータの上書きを防ぐため、変更を停止しています。"
        }
    }

    private func save() {
        guard storageError == nil else { return }
        do {
            let data = try JSONEncoder().encode(TaskSnapshot(items: items, recurringTasks: recurringTasks))
            defaults.set(data, forKey: storageKey)
        } catch {
            storageError = "タスクを保存できませんでした。アプリを終了する前に確認してください。"
        }
    }
}
