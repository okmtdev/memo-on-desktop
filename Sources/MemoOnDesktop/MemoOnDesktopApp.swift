import AppKit
import SwiftUI

@main
struct MemoOnDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = TaskStore()
    @StateObject private var integrations = IntegrationStore()
    @StateObject private var meetings = MeetingStore()
    @StateObject private var windowPresentation = WindowPresentation.shared

    var body: some Scene {
        Window("MemoOnDesktop", id: "main") {
            MainView()
                .environmentObject(store)
                .environmentObject(integrations)
                .environmentObject(meetings)
                .background(MainWindowRegistration(presentation: windowPresentation))
                .frame(minWidth: 760, minHeight: 560)
                .onAppear { AppActivation.focusMainWindow() }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1040, height: 720)

        Window("連携設定", id: "integrations") {
            IntegrationSettingsView()
                .environmentObject(integrations)
                .environmentObject(meetings)
        }
        .defaultSize(width: 760, height: 760)

        Window("定期タスク", id: "recurring") {
            RecurringTasksView().environmentObject(store)
        }
        .defaultSize(width: 720, height: 600)

        MenuBarExtra("MemoOnDesktop", systemImage: "checkmark.square") {
            MenuBarActions()
        }
        .commands {
            CommandGroup(after: .windowArrangement) {
                Toggle("常に最前面に表示", isOn: $windowPresentation.alwaysOnTop)
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Also allow keyboard activation when launched as a SwiftPM executable.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppActivation.focusMainWindow()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let pin = NSMenuItem(title: "常に最前面に表示", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        pin.target = self
        pin.state = WindowPresentation.shared.alwaysOnTop ? .on : .off
        menu.addItem(pin)
        return menu
    }

    @objc private func toggleAlwaysOnTop() {
        WindowPresentation.shared.alwaysOnTop.toggle()
    }
}

@MainActor
private enum AppActivation {
    static func focusMainWindow() {
        // Let SwiftUI create the window and let the status menu finish closing.
        DispatchQueue.main.async {
            let app = NSApplication.shared
            guard let window = app.windows.first(where: { $0.identifier?.rawValue == "main" })
                    ?? app.mainWindow else { return }
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // An open composer sheet, rather than its parent, receives typing.
            window.attachedSheet?.makeKeyAndOrderFront(nil)
        }
    }
}

private struct MenuBarActions: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var windowPresentation = WindowPresentation.shared

    var body: some View {
        Toggle("常に最前面に表示", isOn: $windowPresentation.alwaysOnTop)
        Divider()
        Button("MemoOnDesktopを開く") {
            openWindow(id: "main")
            AppActivation.focusMainWindow()
        }
        Button("連携設定…") {
            openWindow(id: "integrations")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("定期タスク…") {
            openWindow(id: "recurring")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("MemoOnDesktopを終了") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

extension TaskKind {
    var tint: Color { self == .work ? Color.accentColor : Color.teal }
}

struct MainView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var meetings: MeetingStore
    @StateObject private var views = SavedViewsStore()
    @ObservedObject private var windowPresentation = WindowPresentation.shared
    @AppStorage("memo-on-desktop.hidePersonal", store: UserDefaults(suiteName: "MemoOnDesktop")) private var hidePersonal = false
    @State private var showingReview = false
    @State private var showingNameEditor = false
    @State private var renamingView = false
    @State private var viewName = ""
    @State private var showingComposer = false
    @State private var editingTaskID: UUID?
    @State private var composerHeight: CGFloat = 450
    @State private var now = Date()

    private var today: TaskDay { TaskDay(now) }
    private var showingForm: Bool { showingComposer || editingTaskID != nil }
    private var visibleItems: [TodoItem] {
        views.configuration.items(store.items, today: today, hidePersonal: hidePersonal)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                if showingReview {
                    ReviewView(items: store.items, now: now, hidePersonal: hidePersonal, onEdit: edit)
                } else {
                    workspace
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(showingForm)
        .accessibilityHidden(showingForm)
        .overlay {
            GeometryReader { geometry in
                if showingForm {
                    ZStack {
                        Color.black.opacity(0.18)
                            .contentShape(Rectangle())
                            .onTapGesture { dismissForm() }
                            .accessibilityLabel("タスク入力を閉じる")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { dismissForm() }
                        ScrollView {
                            formContent
                                .background(GeometryReader { content in
                                    Color.clear.preference(key: ComposerHeightKey.self, value: content.size.height)
                                })
                        }
                        .frame(width: 500, height: min(composerHeight, max(100, geometry.size.height - 32)))
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                        .onTapGesture { }
                        .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
                        .onPreferenceChange(ComposerHeightKey.self) { composerHeight = $0 }
                    }
                }
            }
        }
        .onExitCommand { dismissForm() }
        .sheet(isPresented: $showingNameEditor) {
            ViewNameEditor(title: renamingView ? "ビューの名前を変更" : "新しいビューを保存", name: $viewName) {
                if renamingView { views.rename(viewName) } else { views.saveAs(viewName) }
                showingReview = false
                showingNameEditor = false
            } onCancel: { showingNameEditor = false }
        }
        .task {
            store.generateRecurringTasks()
            await meetings.refresh()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) {
            now = $0
            store.generateRecurringTasks(today: TaskDay(now))
            Task { await meetings.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            now = Date()
            store.generateRecurringTasks(today: TaskDay(now))
            Task { await meetings.refresh() }
        }
    }

    @ViewBuilder
    private var formContent: some View {
        if showingComposer {
            QuickAddView(title: $store.draftTitle, kind: $store.draftKind, urlText: $store.draftURL,
                         dueDate: $store.draftDueDate, priority: $store.draftPriority,
                         recurrence: $store.draftRecurrence, today: today) { title, kind, url, dueDate, priority, recurrence in
                guard store.add(title: title, kind: kind, url: url, dueDate: dueDate,
                                priority: priority, recurrence: recurrence) else { return }
                store.resetDraft()
                dismissForm()
                if recurrence != nil { openWindow(id: "recurring") }
            }
        } else if let id = editingTaskID, let draft = store.editDrafts[id] {
            TaskEditorView(draft: Binding(get: { store.editDrafts[id] ?? draft }, set: { store.editDrafts[id] = $0 }),
                           today: today, isRecurring: store.items.first { $0.id == id }?.recurringTaskID != nil) {
                guard let latest = store.editDrafts[id],
                      store.update(id, title: latest.title, kind: latest.kind, url: TaskLink.parse(latest.urlText),
                                   dueDate: latest.dueDate, priority: latest.priority) else { return }
                dismissForm()
            }
        }
    }

    private func dismissForm() {
        showingComposer = false
        editingTaskID = nil
    }

    private func edit(_ item: TodoItem) {
        store.beginEditing(item)
        editingTaskID = item.id
    }

    private func nameView(rename: Bool = false) {
        renamingView = rename
        viewName = rename ? views.selected.name : "ビュー \(views.views.count + 1)"
        showingNameEditor = true
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 25, weight: .semibold)).foregroundStyle(Color.accentColor.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daymark").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("Make room for progress.").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 26)

            VStack(spacing: 8) {
                HStack {
                    Text("マイビュー").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { nameView() } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).help("現在の条件を新しいビューとして保存")
                }.padding(.horizontal, 12)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(views.views) { view in
                            Button {
                                views.select(view.id)
                                showingReview = false
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "square.stack.3d.up").frame(width: 18)
                                    Text(view.name).lineLimit(1)
                                    Spacer(minLength: 2)
                                    let configuration = view.id == views.selectedID ? views.configuration : view.configuration
                                    Text("\(configuration.items(store.items, today: today, hidePersonal: hidePersonal).count)")
                                        .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.system(size: 12, weight: view.id == views.selectedID && !showingReview ? .semibold : .regular))
                                .foregroundStyle(view.id == views.selectedID && !showingReview ? Color.accentColor : Color.primary)
                                .padding(.horizontal, 12).padding(.vertical, 11)
                                .background(view.id == views.selectedID && !showingReview ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("名前を変更…") { views.select(view.id); nameView(rename: true) }
                                Button("削除", role: .destructive) { views.delete(view.id) }
                            }
                        }
                    }
                }
            }.padding(.horizontal, 10)

            Divider().padding(.horizontal, 18)
            Button { showingReview = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line").frame(width: 18)
                    Text("振り返り")
                    Spacer()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(showingReview ? Color.accentColor : Color.primary)
                .padding(12)
                .background(showingReview ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 17) {
                Button { openWindow(id: "recurring") } label: { Label("定期タスク", systemImage: "repeat") }
                Button { openWindow(id: "integrations") } label: { Label("連携設定", systemImage: "link") }
                Button { hidePersonal.toggle() } label: {
                    Label(hidePersonal ? "プライベートを表示" : "プライベートを隠す", systemImage: hidePersonal ? "eye.slash" : "eye")
                }.keyboardShortcut("h", modifiers: [.command, .shift])
            }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 22).padding(.bottom, 22)
        }
        .frame(width: 210)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private var workspace: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                workspaceHeader
                if let error = store.storageError ?? views.storageError {
                    Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 12)
                }
                if let period = views.configuration.calendar.period {
                    if geometry.size.width >= 780 {
                        HStack(spacing: 0) {
                            taskList
                            Divider()
                            calendarPanel(period).frame(width: 290)
                        }
                    } else {
                        VStack(spacing: 0) {
                            taskList
                            Divider()
                            calendarPanel(period).frame(height: min(260, geometry.size.height * 0.38))
                        }
                    }
                } else { taskList }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(views.selected.name).font(.system(size: 26, weight: .bold, design: .rounded)).lineLimit(1)
                    Text("\(visibleItems.count) 件のタスク").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { windowPresentation.alwaysOnTop.toggle() } label: {
                    Image(systemName: windowPresentation.alwaysOnTop ? "pin.fill" : "pin")
                        .foregroundStyle(windowPresentation.alwaysOnTop ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.bordered)
                .help(windowPresentation.alwaysOnTop ? "最前面の固定を解除" : "常に最前面に表示")
                .accessibilityLabel(windowPresentation.alwaysOnTop ? "最前面の固定を解除" : "常に最前面に表示")
                Button { showingComposer = true } label: { Label("タスクを追加", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    .keyboardShortcut("n", modifiers: .command).fixedSize()
            }
            ViewControls(views: views, onSaveAs: { nameView() }, onRename: { nameView(rename: true) })
        }
        .padding(24)
    }

    private func calendarPanel(_ period: MeetingPeriod) -> some View {
        MeetingsPanel(period: period, now: now,
                      isVisible: Binding(get: { views.configuration.calendar != .hidden }, set: { if !$0 { views.configuration.calendar = .hidden } }),
                      includeAllDay: views.configuration.includeAllDay,
                      hideEnded: views.configuration.hideEndedMeetings)
    }

    private var taskList: some View {
        Group {
            if visibleItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.slash").font(.system(size: 28, weight: .light)).foregroundStyle(Color.accentColor)
                    Text("この条件のタスクはありません").font(.system(size: 14, weight: .semibold))
                    Text("フィルターを変えるか、新しくタスクを追加しましょう。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("タスクを追加") { showingComposer = true }.buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    TaskListContent(items: visibleItems, section: .all, today: today, onEdit: edit)
                        .padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QuickAddView: View {
    @FocusState private var fieldFocused: Bool
    @Binding var title: String
    @Binding var kind: TaskKind
    @Binding var urlText: String
    @Binding var dueDate: TaskDay?
    @Binding var priority: TaskPriority
    @Binding var recurrence: RecurrenceDraft
    let today: TaskDay

    let onAdd: (String, TaskKind, URL?, TaskDay?, TaskPriority, RecurrenceRule?) -> Void

    private var hasInvalidURL: Bool {
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && TaskLink.parse(urlText) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("タスクを追加").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("思いついたことを、ここに書き留めましょう")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            TextField("例：次回の会議までに仕様を確認する", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(12)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                .focused($fieldFocused)
                .onSubmit(add)
            VStack(alignment: .leading, spacing: 6) {
                Text("関連URL（任意）")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Slack・NotionなどのURL（https://…）", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(12)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                    .onSubmit(add)
                if hasInvalidURL {
                    Text("http:// または https:// で始まるURLを入力してください")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                } else if let url = TaskLink.parse(urlText) {
                    TaskLinkView(url: url)
                        .id(url)
                }
            }
            HStack {
                Text(recurrence.frequency == .none ? "締め切り（任意）" : "開始日（任意）")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                DeadlinePicker(dueDate: $dueDate, today: today, isStartDate: recurrence.frequency != .none)
            }
            HStack {
                Text("優先度").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Picker("優先度", selection: $priority) {
                    ForEach(TaskPriority.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 245)
            }
            RecurrenceEditor(draft: $recurrence, startDate: dueDate, today: today)
            HStack {
                Picker("分類", selection: $kind) {
                    ForEach(TaskKind.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Spacer()
                Button(recurrence.frequency == .none ? "追加" : "定期タスクを作成", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasInvalidURL || !recurrence.isValid)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .task {
            AppActivation.focusMainWindow()
            // Wait until the overlay is mounted before assigning text focus.
            await Task.yield()
            guard !Task.isCancelled else { return }
            fieldFocused = true
        }
    }

    private func add() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasInvalidURL, recurrence.isValid else { return }
        onAdd(title, kind, TaskLink.parse(urlText), dueDate, priority, recurrence.rule)
    }
}
