import SwiftUI

struct TaskSortEditor: View {
    @Binding var rules: [TaskSortRule]
    let onDone: () -> Void

    private var availableFields: [TaskSortOrder] {
        TaskSortOrder.allCases.filter { field in !rules.contains { $0.field == field } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("並び替えの条件").font(.headline)
                Spacer()
                Button("標準に戻す") { rules = TaskSortRule.defaults }.buttonStyle(.link)
            }
            Text("上の条件を優先し、同じ値のタスクを次の条件で並べます。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("第\(index + 1)条件").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help("条件を上へ移動")
                            .accessibilityLabel("第\(index + 1)条件を上へ移動")
                        Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == rules.count - 1).help("条件を下へ移動")
                            .accessibilityLabel("第\(index + 1)条件を下へ移動")
                        Button { if rules.indices.contains(index) && rules.count > 1 { rules.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                            .disabled(rules.count == 1).help("この条件を削除")
                            .accessibilityLabel("第\(index + 1)条件を削除")
                    }.buttonStyle(.plain)
                    HStack(spacing: 12) {
                        Picker("第\(index + 1)条件の項目", selection: fieldBinding(index, fallback: rule.field)) {
                            ForEach(TaskSortOrder.allCases.filter { $0 == rule.field || availableFields.contains($0) }) {
                                Text($0.fieldLabel).tag($0)
                            }
                        }.labelsHidden().frame(maxWidth: .infinity)
                        Picker("第\(index + 1)条件の順序", selection: directionBinding(index, fallback: rule.direction)) {
                            ForEach(TaskSortDirection.allCases, id: \.self) {
                                Text(rule.field.directionLabel($0)).tag($0)
                            }
                        }.labelsHidden().frame(width: 110)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Menu {
                    ForEach(availableFields) { field in
                        Button(field.fieldLabel) { rules.append(TaskSortRule(field)) }
                    }
                } label: { Label("条件を追加", systemImage: "plus") }
                    .fixedSize().disabled(availableFields.isEmpty)
                Spacer()
                Button("完了", action: onDone).keyboardShortcut(.defaultAction)
            }
            Text("期限未設定・完了日時不明のタスクは、どちらの順序でもその項目の末尾に並びます。変更後は「保存」でビューを更新できます。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(width: 360)
    }

    private func fieldBinding(_ index: Int, fallback: TaskSortOrder) -> Binding<TaskSortOrder> {
        Binding(get: { rules.indices.contains(index) ? rules[index].field : fallback }, set: { field in
            guard rules.indices.contains(index), !rules.enumerated().contains(where: { $0.offset != index && $0.element.field == field }) else { return }
            rules[index] = TaskSortRule(field)
        })
    }
    private func directionBinding(_ index: Int, fallback: TaskSortDirection) -> Binding<TaskSortDirection> {
        Binding(get: { rules.indices.contains(index) ? rules[index].direction : fallback }, set: { direction in
            guard rules.indices.contains(index) else { return }
            rules[index].direction = direction
        })
    }
    private func move(_ index: Int, by offset: Int) {
        guard rules.indices.contains(index), rules.indices.contains(index + offset) else { return }
        rules.swapAt(index, index + offset)
    }
}
