import Foundation

enum TaskKind: String, CaseIterable, Codable, Identifiable {
    case work = "仕事"
    case personal = "プライベート"
    var id: String { rawValue }
    var symbol: String { self == .work ? "briefcase.fill" : "leaf.fill" }
}

/// A Gregorian calendar day, without a time or time zone to shift on reload.
struct TaskDay: Codable, Hashable, Comparable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year!
        month = components.month!
        day = components.day!
    }

    func date(timeZone: TimeZone = .autoupdatingCurrent) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Noon avoids DST transitions that can make local midnight ambiguous.
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func adding(days: Int) -> TaskDay {
        let calendar = Calendar(identifier: .gregorian)
        return TaskDay(calendar.date(byAdding: .day, value: days, to: date())!)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    func label(relativeTo today: TaskDay) -> String {
        let dateText = year == today.year ? "\(month)/\(day)" : "\(year)/\(month)/\(day)"
        if self < today { return "期限超過 · \(dateText)" }
        if self == today { return "今日が締め切り" }
        if self == today.adding(days: 1) { return "明日 · \(dateText)" }
        return "\(dateText) 締め切り"
    }
}

struct TodoItem: Identifiable, Codable {
    var id = UUID()
    var title: String
    var kind: TaskKind
    var isComplete = false
    var completedAt: Date? = nil
    var createdAt = Date()
    var url: URL? = nil
    var dueDate: TaskDay? = nil
    var priority: TaskPriority = .middle
    var recurringTaskID: UUID? = nil
    var occurrenceDate: TaskDay? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, kind, isComplete, completedAt, createdAt, url, dueDate, priority, recurringTaskID, occurrenceDate
    }
}

extension TodoItem {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        kind = try values.decode(TaskKind.self, forKey: .kind)
        isComplete = try values.decode(Bool.self, forKey: .isComplete)
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        url = try values.decodeIfPresent(URL.self, forKey: .url)
        dueDate = try values.decodeIfPresent(TaskDay.self, forKey: .dueDate)
        priority = try values.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .middle
        recurringTaskID = try values.decodeIfPresent(UUID.self, forKey: .recurringTaskID)
        occurrenceDate = try values.decodeIfPresent(TaskDay.self, forKey: .occurrenceDate)
    }
}

enum AppSection: String, CaseIterable, Identifiable, Codable {
    case all = "すべて"
    case today = "今日"
    case upcoming = "今後"
    case undated = "期限なし"
    case completed = "完了済み"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: return "tray.full.fill"
        case .today: return "sun.max.fill"
        case .upcoming: return "calendar"
        case .undated: return "tray"
        case .completed: return "checkmark.square.fill"
        }
    }
    var description: String {
        switch self {
        case .all: return "未完了のタスクを締め切り順に"
        case .today: return "今日・今後の締め切り、期限なしの順に"
        case .upcoming: return "明日以降に締め切りがあるタスク"
        case .undated: return "締め切りを決めずに残しておくタスク"
        case .completed: return "完了した日時が新しい順に"
        }
    }
    var emptyMessage: String {
        switch self {
        case .all: return "次にやることを追加しましょう"
        case .today: return "今日進めるタスクはありません"
        case .upcoming: return "これからの予定を追加しましょう"
        case .undated: return "締め切りのないタスクはありません"
        case .completed: return "完了したタスクはここに表示されます"
        }
    }
}

enum TaskSortOrder: String, CaseIterable, Identifiable, Codable {
    case deadline = "期限順", priority = "優先度順", created = "追加順", completed = "完了が新しい順"
    var id: String { rawValue }
    var fieldLabel: String {
        switch self {
        case .deadline: return "期限"
        case .priority: return "優先度"
        case .created: return "作成日"
        case .completed: return "完了日"
        }
    }
    var defaultDirection: TaskSortDirection { self == .created || self == .completed ? .descending : .ascending }
    func directionLabel(_ direction: TaskSortDirection) -> String {
        switch self {
        case .priority: return direction == .ascending ? "高い順" : "低い順"
        case .deadline: return direction == .ascending ? "早い順" : "遅い順"
        case .created, .completed: return direction == .ascending ? "古い順" : "新しい順"
        }
    }
}

enum TaskSortDirection: String, Codable, CaseIterable {
    case ascending, descending
}

struct TaskSortRule: Codable, Equatable {
    var field: TaskSortOrder
    var direction: TaskSortDirection

    init(_ field: TaskSortOrder, direction: TaskSortDirection? = nil) {
        self.field = field
        self.direction = direction ?? field.defaultDirection
    }
    var label: String { "\(field.fieldLabel)（\(field.directionLabel(direction))）" }
    static var defaults: [Self] { [Self(.deadline), Self(.priority)] }
    static func migrating(_ old: TaskSortOrder) -> [Self] {
        switch old {
        case .deadline: return defaults
        case .priority: return [Self(.priority), Self(.deadline)]
        case .created, .completed: return [Self(old)]
        }
    }
    static func normalized(_ rules: [Self]) -> [Self] {
        var fields: Set<TaskSortOrder> = []
        let result = rules.filter { fields.insert($0.field).inserted }
        return result.isEmpty ? defaults : result
    }
}

enum DueFilter: String, CaseIterable, Identifiable, Codable {
    case any = "すべての期限", withDate = "期限あり", withoutDate = "期限なし", overdue = "期限超過", today = "今日", upcoming = "今後"
    var id: String { rawValue }
    func includes(_ item: TodoItem, today: TaskDay) -> Bool {
        switch self {
        case .any: return true
        case .withDate: return item.dueDate != nil
        case .withoutDate: return item.dueDate == nil
        case .overdue: return item.dueDate.map { $0 < today } ?? false
        case .today: return item.dueDate == today
        case .upcoming: return item.dueDate.map { $0 > today } ?? false
        }
    }
}

struct SavedTaskView: Identifiable, Codable {
    var id = UUID()
    var name: String
    var section: AppSection
    var sort: TaskSortOrder
    var priority: TaskPriority?
    var kind: TaskKind?
    var due: DueFilter
    var showTodayMeetings: Bool
    var showUpcomingMeetings: Bool
}

enum TaskList {
    static func customized(_ items: [TodoItem], sortRules: [TaskSortRule], priority: TaskPriority?, kind: TaskKind?, due: DueFilter, today: TaskDay = TaskDay(Date())) -> [TodoItem] {
        let rules = TaskSortRule.normalized(sortRules)
        return items.filter { item in
            (priority == nil || item.priority == priority) && (kind == nil || item.kind == kind) && due.includes(item, today: today)
        }.sorted { lhs, rhs in
            for rule in rules {
                let order: ComparisonResult
                switch rule.field {
                case .deadline: order = compare(lhs.dueDate, rhs.dueDate, direction: rule.direction)
                case .priority: order = compare(lhs.priority.rank, rhs.priority.rank, direction: rule.direction)
                case .created: order = compare(lhs.createdAt, rhs.createdAt, direction: rule.direction)
                case .completed: order = compare(lhs.completedAt, rhs.completedAt, direction: rule.direction)
                }
                if order != .orderedSame { return order == .orderedAscending }
            }
            // Only break ties after every user-selected field has been compared.
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?, direction: TaskSortDirection) -> ComparisonResult {
        // Missing dates stay last in both directions. Two missing values allow the next rule to decide.
        guard let lhs else { return rhs == nil ? .orderedSame : .orderedDescending }
        guard let rhs else { return .orderedAscending }
        guard lhs != rhs else { return .orderedSame }
        let first = direction == .ascending ? lhs < rhs : lhs > rhs
        return first ? .orderedAscending : .orderedDescending
    }

    static func items(_ items: [TodoItem], in section: AppSection, today: TaskDay, hidePersonal: Bool) -> [TodoItem] {
        items.filter { item in
            guard !hidePersonal || item.kind != .personal else { return false }
            if section == .completed { return item.isComplete }
            guard !item.isComplete else { return false }
            switch section {
            case .all: return true
            case .today: return true
            case .upcoming: return item.dueDate.map { $0 > today } ?? false
            case .undated: return item.dueDate == nil
            case .completed: return false
            }
        }.sorted { lhs, rhs in
            if section == .completed {
                if lhs.completedAt != rhs.completedAt {
                    guard let left = lhs.completedAt else { return false }
                    guard let right = rhs.completedAt else { return true }
                    return left > right
                }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            if lhs.dueDate != rhs.dueDate {
                guard let left = lhs.dueDate else { return false }
                guard let right = rhs.dueDate else { return true }
                return left < right
            }
            if lhs.priority != rhs.priority { return lhs.priority.rank < rhs.priority.rank }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

enum TodayTaskGroup: String, CaseIterable, Identifiable {
    case overdue = "期限超過"
    case dueToday = "今日が締め切り"
    case upcoming = "今後の締め切り"
    case undated = "期限なし"

    var id: String { rawValue }

    func contains(_ item: TodoItem, today: TaskDay) -> Bool {
        guard let dueDate = item.dueDate else { return self == .undated }
        switch self {
        case .overdue: return dueDate < today
        case .dueToday: return dueDate == today
        case .upcoming: return dueDate > today
        case .undated: return false
        }
    }
}

struct TaskEditDraft {
    var title: String
    var kind: TaskKind
    var urlText: String
    var dueDate: TaskDay?
    var priority: TaskPriority

    init(_ item: TodoItem) {
        title = item.title
        kind = item.kind
        urlText = item.url?.absoluteString ?? ""
        dueDate = item.dueDate
        priority = item.priority
    }
}
