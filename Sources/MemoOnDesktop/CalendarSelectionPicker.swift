import SwiftUI

struct CalendarSelectionPicker: View {
    let calendars: [MeetingCalendar]
    let selectedIDs: Set<String>
    let onToggle: (String, Bool) -> Void
    @State private var showing = false
    @State private var search = ""
    @State private var selectedOnly = false

    private var selectedCount: Int { calendars.filter { selectedIDs.contains($0.id) }.count }
    private var filtered: [MeetingCalendar] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return calendars.filter {
            (!selectedOnly || selectedIDs.contains($0.id)) &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.account.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                Text("\(selectedCount)件を選択中")
                Image(systemName: "chevron.down").font(.caption)
            }
        }
        .accessibilityLabel("表示するカレンダーを選択")
        .popover(isPresented: $showing, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("表示するカレンダー").font(.headline)
                    Spacer()
                    Button("完了") { showing = false }
                }
                TextField("カレンダー名・アカウントで検索", text: $search)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Toggle("選択済みのみ", isOn: $selectedOnly).toggleStyle(.checkbox)
                    Spacer()
                    Text("\(filtered.count) / \(calendars.count)件").foregroundStyle(.secondary)
                }
                .font(.caption)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if filtered.isEmpty {
                            Text("該当するカレンダーがありません")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center).padding(.top, 35)
                        }
                        ForEach(filtered) { calendar in
                            Toggle(isOn: Binding(get: { selectedIDs.contains(calendar.id) }, set: { onToggle(calendar.id, $0) })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(calendar.title).font(.callout).lineLimit(2)
                                    Text(calendar.account).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .frame(height: 230)
            }
            .padding(18)
            .frame(width: 390)
        }
    }
}
