import Combine
import Foundation

enum TaskStatusFilter: String, Codable, CaseIterable, Identifiable {
    case open = "未完了", completed = "完了", all = "すべて"
    var id: String { rawValue }
    func includes(_ item: TodoItem) -> Bool {
        self == .all || (self == .completed ? item.isComplete : !item.isComplete)
    }
}

enum CalendarDisplay: String, Codable, CaseIterable, Identifiable {
    case hidden = "非表示", today = "今日", week = "今日から7日間", upcoming = "明日から7日間"
    var id: String { rawValue }
    var period: MeetingPeriod? {
        switch self {
        case .hidden: return nil
        case .today: return .today
        case .week: return .week
        case .upcoming: return .upcoming
        }
    }
}

struct ViewConfiguration: Codable, Equatable {
    var status: TaskStatusFilter = .open
    var sortRules: [TaskSortRule] = TaskSortRule.defaults
    var priority: TaskPriority?
    var kind: TaskKind?
    var due: DueFilter = .any
    var search = ""
    var calendar: CalendarDisplay = .hidden
    var includeAllDay = true
    var hideEndedMeetings = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case status, sortRules, priority, kind, due, search, calendar, includeAllDay, hideEndedMeetings
    }
    private enum LegacyKeys: String, CodingKey { case sort }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decodeIfPresent(TaskStatusFilter.self, forKey: .status) ?? .open
        if let rules = try values.decodeIfPresent([TaskSortRule].self, forKey: .sortRules) {
            sortRules = TaskSortRule.normalized(rules)
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            sortRules = TaskSortRule.migrating(try legacy.decodeIfPresent(TaskSortOrder.self, forKey: .sort) ?? .deadline)
        }
        priority = try values.decodeIfPresent(TaskPriority.self, forKey: .priority)
        kind = try values.decodeIfPresent(TaskKind.self, forKey: .kind)
        due = try values.decodeIfPresent(DueFilter.self, forKey: .due) ?? .any
        search = try values.decodeIfPresent(String.self, forKey: .search) ?? ""
        calendar = try values.decodeIfPresent(CalendarDisplay.self, forKey: .calendar) ?? .hidden
        includeAllDay = try values.decodeIfPresent(Bool.self, forKey: .includeAllDay) ?? true
        hideEndedMeetings = try values.decodeIfPresent(Bool.self, forKey: .hideEndedMeetings) ?? false
    }

    var filterCount: Int {
        (priority == nil ? 0 : 1) + (kind == nil ? 0 : 1) + (due == .any ? 0 : 1)
    }

    func items(_ items: [TodoItem], today: TaskDay, hidePersonal: Bool) -> [TodoItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = items.filter {
            status.includes($0) && (!hidePersonal || $0.kind != .personal)
                && (query.isEmpty || $0.title.localizedStandardContains(query))
        }
        return TaskList.customized(filtered, sortRules: sortRules, priority: priority, kind: kind, due: due, today: today)
    }
}

struct WorkspaceView: Codable, Identifiable {
    var id = UUID()
    var name: String
    var configuration = ViewConfiguration()
}

@MainActor
final class SavedViewsStore: ObservableObject {
    @Published private(set) var views: [WorkspaceView] = []
    @Published private(set) var selectedID: UUID
    @Published var configuration: ViewConfiguration {
        didSet {
            drafts[selectedID] = configuration
            persist()
        }
    }
    @Published private(set) var storageError: String?
    private var drafts: [UUID: ViewConfiguration] = [:]
    private let defaults: UserDefaults
    private let key = "memo-on-desktop.views.v2"
    private struct Snapshot: Codable {
        var views: [WorkspaceView]
        var selectedID: UUID
        var drafts: [UUID: ViewConfiguration]
    }

    init(defaults: UserDefaults = UserDefaults(suiteName: "MemoOnDesktop") ?? .standard) {
        self.defaults = defaults
        let initial = WorkspaceView(name: "マイビュー")
        selectedID = initial.id
        configuration = initial.configuration
        views = [initial]
        do {
            if let data = defaults.data(forKey: key) {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                if !snapshot.views.isEmpty {
                    views = snapshot.views
                    drafts = snapshot.drafts
                    selectedID = views.contains { $0.id == snapshot.selectedID } ? snapshot.selectedID : views[0].id
                    configuration = drafts[selectedID] ?? selected.configuration
                }
            } else if let data = defaults.data(forKey: "memo-on-desktop.savedViews.v1"), !data.isEmpty {
                let legacy = try JSONDecoder().decode([SavedTaskView].self, from: data)
                if !legacy.isEmpty {
                    views = legacy.map { old in
                        var config = ViewConfiguration()
                        config.status = old.section == .completed ? .completed : .open
                        config.sortRules = TaskSortRule.migrating(old.section == .completed ? .completed : old.sort)
                        config.priority = old.priority
                        config.kind = old.kind
                        config.due = old.due
                        if old.due == .any {
                            if old.section == .upcoming { config.due = .upcoming }
                            if old.section == .undated { config.due = .withoutDate }
                        }
                        if old.section == .today && old.showTodayMeetings { config.calendar = .today }
                        if old.section == .upcoming && old.showUpcomingMeetings { config.calendar = .upcoming }
                        return WorkspaceView(id: old.id, name: old.name, configuration: config)
                    }
                    selectedID = views[0].id
                    configuration = views[0].configuration
                }
            }
        } catch {
            storageError = "保存したビューを読み込めませんでした。元の保存データは保持しています。"
        }
        persist()
    }

    var selected: WorkspaceView { views.first { $0.id == selectedID } ?? views[0] }
    var hasChanges: Bool { configuration != selected.configuration }

    func select(_ id: UUID) {
        guard let view = views.first(where: { $0.id == id }) else { return }
        selectedID = id
        configuration = drafts[id] ?? view.configuration
    }

    func save() {
        guard storageError == nil, let index = views.firstIndex(where: { $0.id == selectedID }) else { return }
        views[index].configuration = configuration
        drafts.removeValue(forKey: selectedID)
        persist()
    }

    func saveAs(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storageError == nil, !name.isEmpty else { return }
        let view = WorkspaceView(name: name, configuration: configuration)
        views.append(view)
        selectedID = view.id
        persist()
    }

    func rename(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storageError == nil, !name.isEmpty, let index = views.firstIndex(where: { $0.id == selectedID }) else { return }
        views[index].name = name
        persist()
    }

    func discardChanges() {
        configuration = selected.configuration
        drafts.removeValue(forKey: selectedID)
        persist()
    }

    func delete(_ id: UUID) {
        guard storageError == nil else { return }
        views.removeAll { $0.id == id }
        drafts.removeValue(forKey: id)
        if views.isEmpty { views = [WorkspaceView(name: "マイビュー")] }
        if selectedID == id { select(views[0].id) }
        persist()
    }

    private func persist() {
        guard storageError == nil else { return }
        do {
            let data = try JSONEncoder().encode(Snapshot(views: views, selectedID: selectedID, drafts: drafts))
            defaults.set(data, forKey: key)
        } catch {
            storageError = "ビューを保存できませんでした。"
        }
    }
}
