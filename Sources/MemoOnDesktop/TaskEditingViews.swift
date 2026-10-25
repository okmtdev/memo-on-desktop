import SwiftUI

struct InlineTaskTitle: View {
    let title: String
    let isComplete: Bool
    let onSave: (String) -> Bool
    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("タスクのタイトル", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { save(endOnFailure: false) }
                        .onExitCommand { finish() }
                        .task {
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            focused = true
                        }
                        .onChange(of: focused) { if !$0 && editing { save(endOnFailure: true) } }
                        .onDisappear { if editing { save(endOnFailure: true) } }
                    Text(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "タイトルは空にできません。Escで元に戻せます。"
                         : "Enterで保存 · Escで取り消し")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    draft = title
                    editing = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .foregroundStyle(isComplete ? .secondary : .primary)
                            .strikethrough(isComplete)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "pencil")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .opacity(hovering ? 1 : 0.35)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("クリックしてタイトルを編集。Enterで保存、Escで取り消し")
                .accessibilityLabel("タイトルを編集：\(title)")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save(endOnFailure: Bool) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if (!trimmed.isEmpty && onSave(trimmed)) || endOnFailure { finish() }
    }

    private func finish() {
        editing = false
        focused = false
    }
}

struct TaskEditorView: View {
    @Binding var draft: TaskEditDraft
    let today: TaskDay
    let isRecurring: Bool
    let onSave: () -> Void
    @FocusState private var titleFocused: Bool

    private var invalidURL: Bool {
        !draft.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && TaskLink.parse(draft.urlText) == nil
    }
    private var canSave: Bool { !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !invalidURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("タスクを編集").font(.system(size: 19, weight: .bold, design: .rounded))
            Text("保存すると一覧に反映します。入力途中の内容は、閉じてもアプリ終了まで保持します。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("タイトル").font(.caption).foregroundStyle(.secondary)
                TextField("タスクのタイトル", text: $draft.title)
                    .textFieldStyle(.roundedBorder).focused($titleFocused)
                    .onSubmit(save)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("関連URL（任意）").font(.caption).foregroundStyle(.secondary)
                TextField("Slack・NotionなどのURL（https://…）", text: $draft.urlText)
                    .textFieldStyle(.roundedBorder).onSubmit(save)
                if invalidURL {
                    Text("http:// または https:// で始まるURLを入力してください")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                Text("分類").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("分類", selection: $draft.kind) {
                    ForEach(TaskKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 245)
            }
            HStack {
                Text("優先度").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("優先度", selection: $draft.priority) {
                    ForEach(TaskPriority.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 245)
            }
            HStack {
                Text("締め切り（任意）").font(.caption).foregroundStyle(.secondary)
                Spacer()
                DeadlinePicker(dueDate: $draft.dueDate, today: today)
            }
            if isRecurring {
                Text("この回のタスクだけを変更します。定期タスクのルールや、ほかの回には反映しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("外側をクリックすると閉じます").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent).disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            titleFocused = true
        }
    }

    private func save() { if canSave { onSave() } }
}
