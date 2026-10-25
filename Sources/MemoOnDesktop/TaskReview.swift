import Foundation

enum ReviewPeriod: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, quarter = 90
    var id: Int { rawValue }
    var label: String { "\(rawValue)日間" }
}

struct ReviewDay: Identifiable {
    var date: Date
    var completed: Int
    var created: Int
    var id: Date { date }
}

struct DurationBucket: Identifiable {
    var label: String
    var count: Int
    var id: String { label }
}

enum OpenTaskAttention: Int, CaseIterable, Identifiable {
    case watch = 7, elevated = 14, critical = 30
    var id: Int { rawValue }
    var rangeLabel: String {
        switch self {
        case .watch: return "7〜13日"
        case .elevated: return "14〜29日"
        case .critical: return "30日以上"
        }
    }
    var label: String {
        switch self {
        case .watch: return "要確認"
        case .elevated: return "要注意"
        case .critical: return "長期滞留"
        }
    }
    static func level(days: Int) -> Self? {
        allCases.reversed().first { days >= $0.rawValue }
    }
}

struct TaskReview {
    let now: Date
    let calendar: Calendar
    let period: ReviewPeriod
    let start: Date
    let previousStart: Date
    let completed: [TodoItem]
    let previousCompleted: [TodoItem]
    let created: [TodoItem]
    let open: [TodoItem]
    let overdue: [TodoItem]
    let days: [ReviewDay]
    let unknownCompletionCount: Int
    let invalidDurationCount: Int
    let futureRecurringCount: Int

    init(items: [TodoItem], period: ReviewPeriod, now: Date, kind: TaskKind? = nil,
         hidePersonal: Bool = false, includeRecurring: Bool = true, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
        self.period = period
        let today = calendar.startOfDay(for: now)
        start = calendar.date(byAdding: .day, value: -(period.rawValue - 1), to: today)!
        previousStart = calendar.date(byAdding: .day, value: -period.rawValue, to: start)!
        let scope = items.filter {
            (!hidePersonal || $0.kind != .personal) && (kind == nil || $0.kind == kind)
                && (includeRecurring || $0.recurringTaskID == nil)
        }
        let start = self.start
        let previousStart = self.previousStart
        completed = scope.filter { item in
            guard item.isComplete, let date = item.completedAt else { return false }
            return date >= start && date <= now
        }.sorted { $0.completedAt! > $1.completedAt! }
        previousCompleted = scope.filter { item in
            guard item.isComplete, let date = item.completedAt else { return false }
            return date >= previousStart && date < start
        }
        created = scope.filter { $0.createdAt >= start && $0.createdAt <= now }
        let todayDay = TaskDay(now, timeZone: calendar.timeZone)
        let futureRecurring = scope.filter {
            !$0.isComplete && $0.recurringTaskID != nil && ($0.occurrenceDate.map { $0 > todayDay } ?? false)
        }
        futureRecurringCount = futureRecurring.count
        let futureIDs = Set(futureRecurring.map(\.id))
        open = scope.filter { !$0.isComplete && $0.createdAt <= now && !futureIDs.contains($0.id) }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString }
        overdue = open.filter { $0.dueDate.map { $0 < todayDay } ?? false }
        unknownCompletionCount = scope.filter { $0.isComplete && $0.completedAt == nil }.count
        invalidDurationCount = completed.filter { $0.completedAt! < $0.createdAt }.count
        let completedByDay = Dictionary(grouping: completed) { calendar.startOfDay(for: $0.completedAt!) }
        let createdByDay = Dictionary(grouping: created) { calendar.startOfDay(for: $0.createdAt) }
        days = (0..<period.rawValue).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            return ReviewDay(date: day, completed: completedByDay[day]?.count ?? 0, created: createdByDay[day]?.count ?? 0)
        }
    }

    static func duration(_ item: TodoItem) -> TimeInterval? {
        guard item.isComplete, let completed = item.completedAt, completed >= item.createdAt else { return nil }
        return completed.timeIntervalSince(item.createdAt)
    }
    var durations: [TimeInterval] { completed.compactMap(Self.duration).sorted() }
    var median: TimeInterval? { Self.percentile(durations, fraction: 0.5) }
    var previousMedian: TimeInterval? { Self.percentile(previousCompleted.compactMap(Self.duration).sorted(), fraction: 0.5) }
    var p90: TimeInterval? {
        let values = durations
        guard !values.isEmpty else { return nil }
        // Nearest rank keeps the “90% completed within” statement true for small samples too.
        return values[max(0, Int((Double(values.count) * 0.9).rounded(.up)) - 1)]
    }
    var average: TimeInterval? { durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count) }
    var activeDays: Int { days.filter { $0.completed > 0 }.count }
    var dailyAverage: Double { Double(completed.count) / Double(period.rawValue) }
    var completionDifference: Int { completed.count - previousCompleted.count }
    var datedCompleted: [TodoItem] { completed.filter { $0.dueDate != nil } }
    var onTimeCount: Int {
        datedCompleted.filter { TaskDay($0.completedAt!, timeZone: calendar.timeZone) <= $0.dueDate! }.count
    }
    var onTimeRate: Double? { datedCompleted.isEmpty ? nil : Double(onTimeCount) / Double(datedCompleted.count) }
    func openDays(_ item: TodoItem) -> Int { max(0, Int(now.timeIntervalSince(item.createdAt) / 86400)) }
    var aging: [TodoItem] { open.filter { OpenTaskAttention.level(days: openDays($0)) != nil } }
    func agingCount(_ level: OpenTaskAttention) -> Int {
        aging.filter { OpenTaskAttention.level(days: openDays($0)) == level }.count
    }
    var attentionItems: [TodoItem] {
        let overdueIDs = Set(overdue.map(\.id))
        return open.sorted {
            let leftOverdue = overdueIDs.contains($0.id), rightOverdue = overdueIDs.contains($1.id)
            if leftOverdue != rightOverdue { return leftOverdue }
            if leftOverdue && $0.dueDate != $1.dueDate { return $0.dueDate! < $1.dueDate! }
            return $0.createdAt < $1.createdAt
        }
    }
    var durationBuckets: [DurationBucket] {
        let bounds: [(String, Double, Double)] = [
            ("1時間未満", 0, 3600), ("1〜24時間", 3600, 86400), ("1〜3日", 86400, 3 * 86400),
            ("3〜7日", 3 * 86400, 7 * 86400), ("7日以上", 7 * 86400, .infinity)
        ]
        return bounds.map { label, lower, upper in
            DurationBucket(label: label, count: durations.filter { $0 >= lower && $0 < upper }.count)
        }
    }

    /// Linear interpolation, including even-sized samples; the input is sorted.
    static func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let index = Double(values.count - 1) * fraction
        let lower = Int(index.rounded(.down)), upper = Int(index.rounded(.up))
        return values[lower] + (values[upper] - values[lower]) * (index - Double(lower))
    }

    static func formatDuration(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        if value < 60 { return "1分未満" }
        if value < 3600 { return "\(Int(value / 60))分" }
        if value < 86400 { return String(format: "%.1f時間", value / 3600) }
        return String(format: "%.1f日", value / 86400)
    }
}
