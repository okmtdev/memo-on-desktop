import Charts
import SwiftUI

struct ReviewView: View {
    let items: [TodoItem]
    let now: Date
    let hidePersonal: Bool
    let onEdit: (TodoItem) -> Void
    @State private var period: ReviewPeriod = .month
    @State private var kind: TaskKind?
    @State private var includeRecurring = true
    @State private var selectedDay: Date?

    private var review: TaskReview {
        TaskReview(items: items, period: period, now: now, kind: kind, hidePersonal: hidePersonal, includeRecurring: includeRecurring)
    }

    var body: some View {
        GeometryReader { geometry in
        let data = review
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(data)
                AgingTasksCard(review: data, onEdit: onEdit)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: geometry.size.width >= 800 ? 4 : 2), spacing: 12) {
                    metric("完了したタスク", value: "\(data.completed.count)", unit: "件", symbol: "checkmark.circle", color: .accentColor,
                           detail: "前の\(period.label)より \(signed(data.completionDifference)) 件")
                    metric("完了までの中央値", value: TaskReview.formatDuration(data.median), symbol: "clock", color: .teal,
                           detail: medianComparison(data))
                    metric("1日あたりの完了", value: String(format: "%.1f", data.dailyAverage), unit: "件", symbol: "chart.bar", color: .indigo,
                           detail: "完了のあった日 \(data.activeDays) / \(period.rawValue) 日")
                    metric("期限内に完了", value: data.onTimeRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", symbol: "calendar.badge.checkmark", color: .orange,
                           detail: "期限付き \(data.datedCompleted.count) 件中 \(data.onTimeCount) 件")
                }
                trend(data)
                if selectedDay != nil { completionList(data) }
                durationDistribution(data)
                nextSteps(data)
                if selectedDay == nil { completionList(data) }
                methodology(data)
            }
            .padding(24)
        }
        .onChange(of: period) { _ in selectedDay = nil }
        .onChange(of: kind) { _ in selectedDay = nil }
        .onChange(of: hidePersonal) { hidden in if hidden && kind == .personal { kind = nil } }
        }
    }

    private func header(_ data: TaskReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("振り返り").font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("進んだことと、次に動かすこと。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chart.xyaxis.line").font(.system(size: 28, weight: .light)).foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 12) {
                Picker("集計期間", selection: $period) {
                    ForEach(ReviewPeriod.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 250)
                Menu {
                    Picker("分類", selection: $kind) {
                        Text("すべての分類").tag(TaskKind?.none)
                        ForEach(TaskKind.allCases.filter { !hidePersonal || $0 != .personal }) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    Divider()
                    Toggle("定期タスクを含める", isOn: $includeRecurring)
                } label: { Label(kind?.rawValue ?? "すべての分類", systemImage: "line.3.horizontal.decrease") }.fixedSize()
            }
            Text("\(data.start.formatted(.dateTime.month().day().locale(Locale(identifier: "ja_JP")))) – \(now.formatted(.dateTime.month().day().locale(Locale(identifier: "ja_JP")))) · 今日の途中まで\(includeRecurring ? " · 定期タスクを含む" : " · 単発タスクのみ")")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, value: String, unit: String = "", symbol: String, color: Color, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(color)
                Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
            }.monospacedDigit()
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading).padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.05)))
    }

    private func trend(_ data: TaskReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("日々のペース").font(.system(size: 14, weight: .semibold))
                    Text("完了 \(data.completed.count) 件 / 追加 \(data.created.count) 件")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if selectedDay != nil { Button("選択を解除") { selectedDay = nil }.buttonStyle(.link).font(.caption) }
            }
            Chart {
                ForEach(data.days) { day in
                    BarMark(x: .value("日", day.date, unit: .day), y: .value("件数", day.completed))
                        .foregroundStyle(by: .value("種類", "完了"))
                        .cornerRadius(3)
                    LineMark(x: .value("日", day.date, unit: .day), y: .value("件数", day.created))
                        .foregroundStyle(by: .value("種類", "追加"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                if let selectedDay {
                    RuleMark(x: .value("選択日", selectedDay, unit: .day))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }
            }
            .chartForegroundStyleScale(["完了": Color.accentColor, "追加": Color.secondary.opacity(0.55)])
            .chartXScale(domain: data.start...Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!)
            .chartYScale(domain: 0...max(1, data.days.map { max($0.completed, $0.created) }.max() ?? 1))
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: period == .week ? 1 : (period == .month ? 5 : 15))) { _ in
                AxisValueLabel(format: .dateTime.month().day().locale(Locale(identifier: "ja_JP")))
            } }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let plot = geometry[proxy.plotAreaFrame]
                            guard plot.contains(value.location), let date: Date = proxy.value(atX: value.location.x - plot.minX) else { return }
                            let day = Calendar.current.startOfDay(for: date)
                            if data.days.contains(where: { $0.date == day }) { selectedDay = day }
                        })
                }
            }
            .frame(height: 190)
            if let selectedDay, let day = data.days.first(where: { $0.date == selectedDay }) {
                Text("\(selectedDay.formatted(.dateTime.month().day().locale(Locale(identifier: "ja_JP"))))：完了 \(day.completed) 件 / 追加 \(day.created) 件")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
            } else {
                Text("グラフの日付をクリックすると、その日に完了したタスクを下で確認できます。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.reviewCard()
    }

    private func durationDistribution(_ data: TaskReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("完了までに、どれくらい？").font(.system(size: 14, weight: .semibold))
            Text("作成から完了までの経過時間。待ち時間も含みます。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if data.durations.isEmpty {
                Text("完了日時が記録されたタスクが増えると、時間の傾向が見えてきます。")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ForEach(data.durationBuckets) { bucket in
                    HStack(spacing: 12) {
                        Text(bucket.label).font(.system(size: 11)).frame(width: 70, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.teal.opacity(0.07))
                                Capsule().fill(Color.teal.opacity(0.65))
                                    .frame(width: geometry.size.width * Double(bucket.count) / Double(max(1, data.durations.count)))
                            }
                        }.frame(height: 7)
                        Text("\(bucket.count) 件").font(.system(size: 10)).monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                }
                Divider()
                Text("平均 \(TaskReview.formatDuration(data.average))  ·  90%が \(TaskReview.formatDuration(data.p90)) 以内に完了  ·  \(data.durations.count) 件を集計")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.reviewCard()
    }

    private func nextSteps(_ data: TaskReview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("次に動かすタスク").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("現在の未完了 \(data.open.count) 件").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("期限超過 \(data.overdue.count) 件  ·  作成から7日以上 \(data.aging.count) 件")
                .font(.system(size: 11)).foregroundStyle(data.overdue.isEmpty ? Color.secondary : Color.orange)
            if data.open.isEmpty {
                Text("いま見直す未完了タスクはありません。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(data.aging.isEmpty ? "期限超過を優先し、長く残っている順に表示します。次の一歩や期限を見直せます。" : "長く残るタスクは、次の一歩を小さくするか、期限・優先度を見直しましょう。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(Array(data.attentionItems.prefix(5))) { item in
                    Button { onEdit(item) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.priority == .high ? "flag.fill" : "circle").foregroundStyle(item.priority == .high ? Color.orange : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(item.dueDate?.label(relativeTo: TaskDay(now)) ?? "期限なし").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(TaskReview.formatDuration(now.timeIntervalSince(item.createdAt))).font(.system(size: 11)).foregroundStyle(.secondary)
                            Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
                        }.contentShape(Rectangle()).padding(.vertical, 6)
                    }.buttonStyle(.plain)
                }
            }
            if data.futureRecurringCount > 0 {
                Text("未来の回として生成済みの定期タスク \(data.futureRecurringCount) 件は、この見直し候補から除いています。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.reviewCard()
    }

    private func completionList(_ data: TaskReview) -> some View {
        let completed = data.completed.filter { item in
            selectedDay.map { Calendar.current.isDate(item.completedAt!, inSameDayAs: $0) } ?? true
        }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(selectedDay.map { "\($0.formatted(.dateTime.month().day().locale(Locale(identifier: "ja_JP")))) に完了したこと" } ?? "完了したこと")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(completed.count) 件").font(.caption).foregroundStyle(.secondary)
            }
            if completed.isEmpty {
                Text("この期間の完了タスクはありません。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(completed) { item in
                            Button { onEdit(item) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.teal)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.system(size: 12)).lineLimit(2)
                                        Text("\(item.kind.rawValue) · \(item.completedAt!.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "ja_JP"))))")
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(TaskReview.formatDuration(TaskReview.duration(item))).font(.system(size: 11)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).padding(.vertical, 4)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: min(CGFloat(completed.count) * 60, 300))
            }
        }.reviewCard()
    }

    private func methodology(_ data: TaskReview) -> some View {
        DisclosureGroup("集計の見方") {
            VStack(alignment: .leading, spacing: 8) {
                Text("長期未完了は集計期間に関係なく、現在未完了のタスクを作成からの経過日数（24時間で1日）で判定します。7・14・30日で注意を強めます。未来の回として生成された定期タスクは除きます。")
                Text("完了数は、現在完了しているタスクを最終完了日で集計します。未完了へ戻したタスクと削除済みタスクは含みません。過去の数値も現在の記録に応じて変わります。")
                Text("完了までの時間は実作業時間ではありません。中央値は真ん中の値、90%の値は遅めのタスクも含む目安です。定期タスクは自動生成された時刻から数えるため、上のメニューで除いて比較できます。")
                Text("1日あたりの完了は選択期間の全日数で割ります。前期間は直前の同じ日数で、今回の期間には今日の途中までを含みます。期限内完了率は、現在保存されている期限の日付までに完了した割合です。")
                Text("完了日時の記録がない \(data.unknownCompletionCount) 件は期間集計から除外。作成より前の完了日時を持つ \(data.invalidDurationCount) 件は時間集計から除外しています。")
                if hidePersonal { Text("プライベートのタスクは、すべての数値と一覧から除外しています。") }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
        }.font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
    private func medianComparison(_ data: TaskReview) -> String {
        guard let previous = data.previousMedian else { return "比較できる前期間の記録なし" }
        return "前の\(period.label)は \(TaskReview.formatDuration(previous))"
    }
}

private extension View {
    func reviewCard() -> some View {
        self.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.05)))
    }
}
