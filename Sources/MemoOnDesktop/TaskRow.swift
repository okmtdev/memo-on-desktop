import SwiftUI

struct TaskListContent: View {
    let items: [TodoItem]
    let section: AppSection
    let today: TaskDay
    let onEdit: (TodoItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if section == .today {
                ForEach(TodayTaskGroup.allCases) { group in
                    let grouped = items.filter { group.contains($0, today: today) }
                    if !grouped.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 8) {
                                Text(group.rawValue).font(.system(size: 12, weight: .semibold))
                                Text("\(grouped.count)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                                Spacer()
                            }
                            .foregroundStyle(group == .overdue ? Color.red : Color.secondary)
                            .padding(.top, 8).padding(.bottom, 2)
                            ForEach(grouped) { item in
                                TaskRow(item: item, today: today) { onEdit(item) }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            } else {
                ForEach(items) { item in
                    TaskRow(item: item, today: today) { onEdit(item) }
                }
            }
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.openWindow) private var openWindow
    let item: TodoItem
    let today: TaskDay
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("完了", isOn: Binding(get: { item.isComplete }, set: { _ in store.toggle(item) }))
                .toggleStyle(.checkbox).labelsHidden().controlSize(.large)
                .frame(width: 24, height: 24)
                .help(item.isComplete ? "未完了に戻す" : "完了にする")
                .accessibilityLabel("\(item.title)を\(item.isComplete ? "未完了に戻す" : "完了にする")")
            VStack(alignment: .leading, spacing: 7) {
                InlineTaskTitle(title: item.title, isComplete: item.isComplete) { store.rename(item.id, title: $0) }
                    .padding(.top, 3)
                HStack(spacing: 10) {
                    Label(item.kind.rawValue, systemImage: item.kind.symbol)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(item.kind.tint)
                    TaskPriorityMenu(priority: Binding(get: { item.priority }, set: { store.setPriority($0, for: item) }))
                    if item.recurringTaskID != nil {
                        Button { openWindow(id: "recurring") } label: { Label("定期", systemImage: "repeat") }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                DeadlinePicker(dueDate: Binding(get: { item.dueDate }, set: { store.setDueDate($0, for: item) }), today: today, isComplete: item.isComplete)
                if item.isComplete {
                    if let completedAt = item.completedAt {
                        Label {
                            Text(verbatim: "完了：" + completedAt.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "ja_JP"))))
                        } icon: { Image(systemName: "checkmark.square.fill") }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text("完了日時の記録なし").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if let url = item.url { TaskLinkView(url: url) }
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).help("タイトル・分類・URLなどを編集")
                .accessibilityLabel("タスクを編集：\(item.title)")
                Button { store.delete(item) } label: {
                    Image(systemName: "trash").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).help("削除")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.055), lineWidth: 1))
    }
}
