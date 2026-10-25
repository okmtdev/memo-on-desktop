import SwiftUI

struct ViewControls: View {
    @ObservedObject var views: SavedViewsStore
    let onSaveAs: () -> Void
    let onRename: () -> Void
    @State private var showingFilters = false
    @State private var showingSort = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { showingFilters.toggle() } label: {
                    Label(views.configuration.filterCount == 0 ? "フィルター" : "フィルター · \(views.configuration.filterCount)", systemImage: "line.3.horizontal.decrease")
                }
                .popover(isPresented: $showingFilters, arrowEdge: .bottom) { filters }
                Button { showingSort.toggle() } label: {
                    Label("並び替え · \(views.configuration.sortRules.count)", systemImage: "arrow.up.arrow.down")
                }
                .popover(isPresented: $showingSort, arrowEdge: .bottom) {
                    TaskSortEditor(rules: $views.configuration.sortRules) { showingSort = false }
                }
                .fixedSize()
                Menu {
                    Picker("予定の表示期間", selection: $views.configuration.calendar) {
                        ForEach(CalendarDisplay.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    Toggle("終日予定を含める", isOn: $views.configuration.includeAllDay)
                    Toggle("終了した予定を隠す", isOn: $views.configuration.hideEndedMeetings)
                } label: {
                    Label("予定", systemImage: views.configuration.calendar == .hidden ? "calendar" : "calendar.badge.checkmark")
                        .foregroundStyle(views.configuration.calendar == .hidden ? Color.primary : Color.accentColor)
                }
                .fixedSize()
                Spacer(minLength: 0)
                Button {
                    if views.hasChanges { views.save() } else { onSaveAs() }
                } label: { Label(views.hasChanges ? "保存" : "別名で保存", systemImage: "bookmark") }
                    .help(views.hasChanges ? "このビューの変更を保存" : "現在の条件を新しいビューとして保存")
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(views.storageError != nil)
                Menu {
                    Button("新しいビューとして保存…", action: onSaveAs)
                    Button("名前を変更…", action: onRename)
                    Button("保存した条件に戻す") { views.discardChanges() }.disabled(!views.hasChanges)
                    Divider()
                    Button("このビューを削除", role: .destructive) { views.delete(views.selectedID) }
                } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).fixedSize()
                    .help("ビューの操作")
                    .disabled(views.storageError != nil)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("このビューのタスクを検索", text: $views.configuration.search)
                    .textFieldStyle(.plain)
                if !views.configuration.search.isEmpty {
                    Button { views.configuration.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("検索をクリア")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 6) {
                Text(summary).lineLimit(2).help(summary)
                Spacer(minLength: 0)
                if views.hasChanges {
                    Circle().fill(Color.orange).frame(width: 5, height: 5)
                    Text("未保存").fixedSize()
                }
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        var parts = [views.configuration.status.rawValue, views.configuration.sortRules.map(\.label).joined(separator: " → ")]
        if let kind = views.configuration.kind { parts.append(kind.rawValue) }
        if let priority = views.configuration.priority { parts.append(priority.rawValue) }
        if views.configuration.due != .any { parts.append(views.configuration.due.rawValue) }
        return parts.joined(separator: "  ·  ")
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("表示するタスク").font(.headline)
                Spacer()
                Button("リセット") {
                    views.configuration.status = .open
                    views.configuration.kind = nil
                    views.configuration.priority = nil
                    views.configuration.due = .any
                }.buttonStyle(.link)
            }
            Picker("状態", selection: $views.configuration.status) {
                ForEach(TaskStatusFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("分類", selection: $views.configuration.kind) {
                Text("すべて").tag(TaskKind?.none)
                ForEach(TaskKind.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            Picker("優先度", selection: $views.configuration.priority) {
                Text("すべて").tag(TaskPriority?.none)
                ForEach(TaskPriority.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            Picker("期限", selection: $views.configuration.due) {
                ForEach(DueFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Text("複数の条件を組み合わせられます。変更後は「保存」でこのビューを更新できます。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("完了") { showingFilters = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 310)
    }
}

struct ViewNameEditor: View {
    let title: String
    @Binding var name: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("ビュー名", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
            Text("フィルター・検索・並び順・予定の表示条件をまとめて保存します。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("キャンセル", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存", action: save).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 340)
        .onAppear { focused = true }
    }
    private func save() { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSave() } }
}
