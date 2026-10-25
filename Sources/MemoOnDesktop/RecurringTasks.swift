import Foundation

enum TaskPriority: String, Codable, CaseIterable, Identifiable {
    case high = "High", middle = "Middle", low = "Low"
    var id: String { rawValue }
    var rank: Int { Self.allCases.firstIndex(of: self)! }
}

enum TaskWeekday: Int, Codable, CaseIterable, Identifiable {
    case monday = 2, tuesday, wednesday, thursday, friday, saturday, sunday = 1
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .monday: return "月"
        case .tuesday: return "火"
        case .wednesday: return "水"
        case .thursday: return "木"
        case .friday: return "金"
        case .saturday: return "土"
        case .sunday: return "日"
        }
    }
}

extension TaskDay {
    var weekday: TaskWeekday {
        TaskWeekday(rawValue: Calendar(identifier: .gregorian).component(.weekday, from: date()))!
    }
}

enum RecurrenceFrequency: String, Codable, CaseIterable, Identifiable {
    case none = "なし", weekly = "毎週", monthly = "毎月"
    var id: String { rawValue }
}

struct RecurrenceRule: Codable, Equatable {
    var frequency: RecurrenceFrequency
    var weekdays: Set<TaskWeekday>
    var monthDay: Int

    var isValid: Bool {
        switch frequency {
        case .none: return false
        case .weekly: return !weekdays.isEmpty
        case .monthly: return (1...31).contains(monthDay)
        }
    }

    var summary: String {
        switch frequency {
        case .none: return "繰り返しなし"
        case .weekly: return "毎週 " + TaskWeekday.allCases.filter { weekdays.contains($0) }.map(\.label).joined(separator: "・")
        case .monthly: return "毎月\(monthDay)日" + (monthDay >= 29 ? "（日付がなければ月末）" : "")
        }
    }

    func first(onOrAfter start: TaskDay) -> TaskDay? {
        guard isValid else { return nil }
        switch frequency {
        case .weekly:
            return (0..<7).map { start.adding(days: $0) }.first { weekdays.contains($0.weekday) }
        case .monthly:
            let calendar = Calendar(identifier: .gregorian)
            for offset in 0...1 {
                let monthStart = TaskDay(year: start.year, month: start.month, day: 1).date()
                let month = calendar.date(byAdding: .month, value: offset, to: monthStart)!
                let components = calendar.dateComponents([.year, .month], from: month)
                let days = calendar.range(of: .day, in: .month, for: month)!.count
                let candidate = TaskDay(year: components.year!, month: components.month!, day: min(monthDay, days))
                if candidate >= start { return candidate }
            }
            return nil
        case .none: return nil
        }
    }
}

struct RecurrenceDraft {
    var frequency: RecurrenceFrequency = .none
    var weekdays: Set<TaskWeekday>
    var monthDay: Int

    init(referenceDay: TaskDay = TaskDay(Date())) {
        weekdays = [referenceDay.weekday]
        monthDay = referenceDay.day
    }

    var rule: RecurrenceRule? {
        frequency == .none ? nil : RecurrenceRule(frequency: frequency, weekdays: weekdays, monthDay: monthDay)
    }
    var isValid: Bool { frequency == .none || rule?.isValid == true }
}

struct RecurringTask: Identifiable, Codable {
    var id = UUID()
    var title: String
    var kind: TaskKind
    var priority: TaskPriority
    var url: URL?
    var rule: RecurrenceRule
    var startDate: TaskDay
    /// A persistent cursor also remembers deleted/completed occurrences.
    var nextDate: TaskDay
    var isActive = true
}

struct TaskSnapshot: Codable {
    var items: [TodoItem]
    var recurringTasks: [RecurringTask]
}

enum RecurringTaskGenerator {
    /// Generates ahead of time, independently of whether earlier tasks are done.
    @discardableResult
    static func materialize(_ snapshot: inout TaskSnapshot, today: TaskDay) -> Int {
        let horizon = today.adding(days: 30)
        var count = 0
        for index in snapshot.recurringTasks.indices {
            var template = snapshot.recurringTasks[index]
            guard template.isActive, template.rule.isValid else { continue }
            var date = template.nextDate
            let existing = Set(snapshot.items.filter { $0.recurringTaskID == template.id }.compactMap(\.occurrenceDate))
            while date <= horizon {
                if !existing.contains(date) {
                    snapshot.items.insert(TodoItem(title: template.title, kind: template.kind, url: template.url,
                        dueDate: date, priority: template.priority, recurringTaskID: template.id, occurrenceDate: date), at: 0)
                    count += 1
                }
                guard let next = template.rule.first(onOrAfter: date.adding(days: 1)), next > date else { break }
                date = next
            }
            template.nextDate = date
            snapshot.recurringTasks[index] = template
        }
        return count
    }
}
