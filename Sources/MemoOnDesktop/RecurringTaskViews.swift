import SwiftUI

extension TaskPriority {
    var tint: Color {
        switch self {
        case .high: return .red
        case .middle: return .orange
        case .low: return .secondary
        }
    }
}

struct TaskPriorityMenu: View {
    @Binding var priority: TaskPriority
    var body: some View {
        Menu {
            Picker("優先度", selection: $priority) {
                ForEach(TaskPriority.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Label(priority.rawValue, systemImage: "flag.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(priority.tint)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("タスクの優先度を変更")
        .accessibilityLabel("優先度 \(priority.rawValue)")
    }
}

struct RecurrenceEditor: View {
    @Binding var draft: RecurrenceDraft
    let startDate: TaskDay?
    let today: TaskDay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("繰り返し").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Picker("繰り返し", selection: $draft.frequency) {
                    ForEach(RecurrenceFrequency.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 245)
            }
            if draft.frequency == .weekly {
                HStack(spacing: 6) {
                    ForEach(TaskWeekday.allCases) { weekday in
                        Button {
                            if draft.weekdays.contains(weekday) { draft.weekdays.remove(weekday) }
                            else { draft.weekdays.insert(weekday) }
                        } label: {
                            Text(weekday.label)
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(draft.weekdays.contains(weekday) ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(draft.weekdays.contains(weekday) ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("毎週\(weekday.label)曜日")
                        .accessibilityValue(draft.weekdays.contains(weekday) ? "選択済み" : "未選択")
                    }
                }
                if draft.weekdays.isEmpty { Text("曜日を1つ以上選んでください").font(.caption).foregroundStyle(.red) }
            } else if draft.frequency == .monthly {
                HStack {
                    Text("毎月の日付").font(.callout)
                    Picker("毎月の日付", selection: $draft.monthDay) {
                        ForEach(1...31, id: \.self) { day in Text("\(day)日").tag(day) }
                    }
                    .labelsHidden().frame(width: 95)
                    Spacer()
                }
                Text("その日がない月は、月の最終日が締め切りになります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let rule = draft.rule, let first = rule.first(onOrAfter: max(startDate ?? today, today)) {
                Text(verbatim: "最初の締め切り：\(first.year)/\(first.month)/\(first.day)（\(first.weekday.label)）")
                    .font(.caption).foregroundStyle(.secondary)
                Text("30日先までのタスクを生成します。開始日が未設定なら今日から、前回分の完了を待たずに繰り返します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: draft.frequency) { frequency in
            let reference = startDate ?? today
            if frequency == .weekly { draft.weekdays = [reference.weekday] }
            if frequency == .monthly { draft.monthDay = reference.day }
        }
    }
}

struct RecurringTasksView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var hidePersonal = false
    @State private var removing: RecurringTask?
    private var visible: [RecurringTask] { store.recurringTasks.filter { !hidePersonal || $0.kind != .personal } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("定期タスク").font(.title.bold())
                Spacer()
                Toggle("プライベートを隠す", isOn: $hidePersonal).toggleStyle(.checkbox).font(.caption)
            }
            Text("追加画面の『繰り返し』で毎週・毎月を設定できます。起動時・日付更新時に30日先まで自動生成し、アプリを閉じていた間の未生成分は次の起動時に補います。")
                .font(.callout).foregroundStyle(.secondary)
            if let error = store.storageError { Text(error).foregroundStyle(.red) }
            if visible.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "repeat").font(.largeTitle).foregroundStyle(.secondary)
                    Text("定期タスクはまだありません")
                    Text("タスク追加画面で『毎週』『毎月』を選んで登録してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(visible) { template in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(template.title).font(.headline)
                                    Spacer()
                                    Toggle("自動生成", isOn: Binding(get: { template.isActive }, set: { store.setRecurringActive(template.id, active: $0) }))
                                        .toggleStyle(.switch).controlSize(.small)
                                }
                                HStack {
                                    Label(template.rule.summary, systemImage: "repeat")
                                    Spacer()
                                    Text(template.kind.rawValue)
                                    TaskPriorityMenu(priority: Binding(get: { template.priority }, set: { store.setRecurringPriority(template.id, priority: $0) }))
                                }
                                .font(.callout).foregroundStyle(.secondary)
                                if template.isActive, let next = template.rule.first(onOrAfter: max(TaskDay(Date()), template.startDate)) {
                                    Text(verbatim: "次の予定日：\(next.year)/\(next.month)/\(next.day)（\(next.weekday.label)）")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text("優先度の変更は、生成済みの未完了タスクにも反映します。")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("ルールを削除", role: .destructive) { removing = template }
                                        .font(.caption).buttonStyle(.borderless)
                                }
                            }
                            .padding(16)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            Text("停止・削除しても生成済みのタスクは残ります。再開すると、停止中の過去分を追加せず、これからの分を生成します。各タスクの締め切り・優先度は個別に変更できます。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 650, minHeight: 480)
        .confirmationDialog("この定期タスクのルールを削除しますか？生成済みのタスクは残ります。", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("ルールを削除", role: .destructive) {
                if let removing { store.removeRecurring(removing.id) }
                removing = nil
            }
        }
    }
}

struct ComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
