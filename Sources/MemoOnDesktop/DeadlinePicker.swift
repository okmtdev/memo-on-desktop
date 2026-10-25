import SwiftUI

struct DeadlinePicker: View {
    @Binding var dueDate: TaskDay?
    let today: TaskDay
    var isComplete = false
    var isStartDate = false
    @State private var showingCalendar = false
    @State private var selection = Date()

    private var tint: Color {
        guard !isComplete, let dueDate else { return .secondary }
        if dueDate < today { return .red }
        if dueDate == today { return .orange }
        return .accentColor
    }

    var body: some View {
        Button {
            selection = (dueDate ?? today).date()
            showingCalendar = true
        } label: {
            Label(label, systemImage: "calendar")
                .font(.system(size: 11, weight: dueDate == nil ? .regular : .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(isStartDate ? "カレンダーで定期タスクの開始日を設定・変更" : "カレンダーで締め切りを設定・変更")
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(isStartDate ? "開始日" : "締め切り").font(.headline)
                    Spacer()
                    Text("日付のみ").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer(minLength: 0)
                    DatePicker("締め切りの日付", selection: $selection, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                        .environment(\.calendar, Calendar(identifier: .gregorian))
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Button("今日") { selection = today.date() }
                    Button("明日") { selection = today.adding(days: 1).date() }
                    Spacer()
                    Button(isStartDate ? "未設定" : "期限なし") {
                        dueDate = nil
                        showingCalendar = false
                    }
                }
                Divider()
                HStack {
                    Text(verbatim: "\(TaskDay(selection).year)/\(TaskDay(selection).month)/\(TaskDay(selection).day)")
                        .font(.callout).monospacedDigit()
                    Spacer()
                    Button("設定") {
                        dueDate = TaskDay(selection)
                        showingCalendar = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
            .frame(width: 300)
        }
    }

    private var label: String {
        guard let dueDate else { return isStartDate ? "開始日を設定" : "締め切りを設定" }
        if isStartDate { return "\(dueDate.year)/\(dueDate.month)/\(dueDate.day) から" }
        if isComplete { return "\(dueDate.year)/\(dueDate.month)/\(dueDate.day)" }
        return dueDate.label(relativeTo: today)
    }
}
