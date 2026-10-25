import SwiftUI

struct AgingTasksCard: View {
    let review: TaskReview
    let onEdit: (TodoItem) -> Void
    @State private var showingAll = false

    private var strongest: OpenTaskAttention {
        OpenTaskAttention.allCases.reversed().first { review.agingCount($0) > 0 } ?? .watch
    }
    private var displayed: [TodoItem] { showingAll ? review.aging : Array(review.aging.prefix(3)) }

    var body: some View {
        if review.aging.isEmpty {
            Label("7日以上オープンのタスクはありません", systemImage: "checkmark.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color(strongest))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("長期間オープンなタスク").font(.system(size: 14, weight: .semibold))
                        Text("7日以上未完了 · \(review.aging.count) 件")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    ForEach(OpenTaskAttention.allCases) { level in
                        Text("\(level.rangeLabel) · \(review.agingCount(level)) 件")
                            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(review.agingCount(level) > 0 ? color(level) : Color.secondary)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(color(level).opacity(review.agingCount(level) > 0 ? 0.10 : 0.03), in: Capsule())
                    }
                }
                Text("集計期間に関係なく、長く残っている順に表示します。クリックして次の一歩・期限・優先度を見直しましょう。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(displayed) { item in
                            agingRow(item)
                        }
                    }
                }
                .frame(height: min(CGFloat(displayed.count) * 78, showingAll ? 320 : 234))
                if review.aging.count > 3 {
                    Button(showingAll ? "3件に折りたたむ" : "すべての \(review.aging.count) 件を確認") { showingAll.toggle() }
                        .buttonStyle(.link).font(.system(size: 11, weight: .medium))
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(color(strongest).opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(color(strongest).opacity(0.30)))
        }
    }

    private func agingRow(_ item: TodoItem) -> some View {
        let days = review.openDays(item)
        let level = OpenTaskAttention.level(days: days) ?? .watch
        return Button { onEdit(item) } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text("\(item.kind.rawValue) · \(item.dueDate?.label(relativeTo: TaskDay(review.now, timeZone: review.calendar.timeZone)) ?? "期限なし")")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(days)日間オープン").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    Text(level.label).font(.system(size: 10))
                }.foregroundStyle(color(level)).fixedSize()
                Image(systemName: "square.and.pencil").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(10).frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("作成：\(item.createdAt.formatted(.dateTime.year().month().day().locale(Locale(identifier: "ja_JP"))))。クリックして編集")
    }

    private func color(_ level: OpenTaskAttention) -> Color {
        switch level {
        case .watch: return .yellow
        case .elevated: return .orange
        case .critical: return .red
        }
    }
}
