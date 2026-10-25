import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingsPanel: View {
    let period: MeetingPeriod
    let now: Date
    @Binding var isVisible: Bool
    var includeAllDay = true
    var hideEnded = false
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.openWindow) private var openWindow

    private var displayed: [CalendarMeeting] {
        MeetingList.meetings(store.meetings, period: period, now: now).filter {
            (includeAllDay || !$0.allDay) && (!hideEnded || $0.end > now)
        }
    }

    var body: some View {
        Group {
            if isVisible {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(period.title).font(.system(size: 14, weight: .semibold))
                            Text(period.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button { isVisible = false } label: { Image(systemName: "eye.slash") }
                            .buttonStyle(.plain)
                            .help("ミーティングを隠す")
                            .accessibilityLabel("ミーティングを隠す")
                    }
                    HStack(spacing: 8) {
                        Label("カレンダー", systemImage: "calendar")
                        Spacer()
                        Button { openWindow(id: "integrations") } label: { Image(systemName: "gearshape") }
                            .buttonStyle(.plain).help("表示カレンダーを選ぶ")
                            .accessibilityLabel("表示カレンダーを選ぶ")
                        Button { Task { await store.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).disabled(store.isRefreshing)
                            .help("予定を更新").accessibilityLabel("予定を更新")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ScrollView {
                        panelContent.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let updated = store.updatedAt, store.hasAvailableSelection {
                        Text("更新 \(updated.formatted(date: .omitted, time: .shortened)) · Googleから取得")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
            } else {
                VStack {
                    Button { isVisible = true } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "calendar")
                            Text("予定").font(.system(size: 10))
                            Image(systemName: "chevron.left").font(.system(size: 9))
                        }
                        .padding(.vertical, 15)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("ミーティングを表示")
                    .accessibilityLabel("ミーティングを表示")
                    Spacer()
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var panelContent: some View {
        if store.access != .allowed {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "calendar.badge.plus").font(.title2).foregroundStyle(.secondary)
                Text("Googleカレンダーの予定を表示できます。")
                Text(store.message ?? "連携設定でGoogleにログインすると、予定を直接取得できます。")
                    .foregroundStyle(.secondary)
                Button("カレンダーを連携") { openWindow(id: "integrations") }
                    .buttonStyle(.bordered)
            }
            .font(.callout)
        } else if let message = store.message {
            VStack(alignment: .leading, spacing: 12) {
                Text(message).font(.callout).foregroundStyle(.secondary)
                Button("再試行") { Task { await store.refresh(force: true) } }
                Button("連携設定を開く") { openWindow(id: "integrations") }
            }
        } else if !store.hasAvailableSelection {
            VStack(alignment: .leading, spacing: 12) {
                Text("表示するカレンダーを選んでください。")
                Text("連携設定で、Googleアカウントのカレンダーにチェックを入れると予定が表示されます。")
                    .foregroundStyle(.secondary)
                Button("カレンダーを選ぶ") { openWindow(id: "integrations") }
                    .buttonStyle(.bordered)
            }
            .font(.callout)
        } else if store.isRefreshing && displayed.isEmpty {
            ProgressView("予定を読み込み中…").font(.caption)
        } else if displayed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "calendar.badge.checkmark").font(.title2).foregroundStyle(.secondary)
                Text(period == .today ? "今日の予定はありません" : "この7日間の予定はありません")
                Text("選択したGoogleカレンダーの予定を表示します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, event in
                        if index == 0 || day(for: event) != day(for: displayed[index - 1]) {
                            Text(day(for: event).formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP"))))
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.top, index == 0 ? 0 : 4)
                        }
                        MeetingCard(meeting: event, now: now)
                    }
            }
        }
    }

    private func day(for event: CalendarMeeting) -> Date {
        Calendar.current.startOfDay(for: max(event.start, period.interval(now: now).start))
    }
}

private struct MeetingCard: View {
    let meeting: CalendarMeeting
    let now: Date
    private var ongoing: Bool { !meeting.allDay && meeting.start <= now && now < meeting.end }
    private var ended: Bool { meeting.end <= now }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                if meeting.allDay {
                    Text("終日").font(.system(size: 11, weight: .medium))
                } else {
                    Text("\(meeting.start.formatted(date: .omitted, time: .shortened)) – \(meeting.end.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                Spacer(minLength: 0)
                if ongoing { Text("開催中").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green) }
                else if ended { Text("終了").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Text(meeting.title).font(.system(size: 12, weight: .semibold)).lineLimit(3)
            Text(meeting.calendarTitle).font(.system(size: 10)).foregroundStyle(.secondary)
            if let location = meeting.location {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let link = meeting.link {
                Link(destination: link) { Label("予定のリンクを開く", systemImage: "arrow.up.right.square") }
                    .font(.system(size: 10))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ongoing ? Color.green.opacity(0.4) : Color.clear, lineWidth: 1))
        .opacity(ended ? 0.65 : 1)
    }
}

struct CalendarSettingsCard: View {
    @EnvironmentObject private var store: MeetingStore
    @State private var importError: String?
    @State private var showingInstructions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Googleカレンダー", systemImage: "calendar").font(.title2.bold())
                Spacer()
                Text(store.access == .allowed ? "連携済み" : "未連携")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Googleに直接ログインし、予定を読み取ります。Mac標準カレンダーへの同期は不要です。Googleアカウント1つを連携でき、共有カレンダーも選べます。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(store.hasClientConfiguration ? "設定JSONを入れ替える" : "設定JSONを読み込む") { chooseClient() }
                    .disabled(store.isRequestingAccess)
                Button(store.access == .allowed ? "Googleにログインし直す" : "Googleでログイン") {
                    Task { await store.requestAccess() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.hasClientConfiguration || store.isRequestingAccess)
                if store.isRequestingAccess {
                    ProgressView().controlSize(.small)
                    Button("キャンセル") { store.cancelLogin() }
                } else if store.access != .notRequested {
                    Button("連携を解除") {
                        do { try store.disconnect() }
                        catch { importError = "キーチェーンの認証情報を更新できませんでした。アクセス許可を確認してください。" }
                    }
                }
            }
            Text(store.hasClientConfiguration ? "デスクトップ用の認証設定を読み込み済みです。" : "初回は以下の手順でOAuthクライアントを作り、JSONを読み込んでください。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = importError ?? store.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("初回設定の手順", isExpanded: $showingInstructions) {
                VStack(alignment: .leading, spacing: 10) {
                    Link("1. Google Cloud Consoleを開く", destination: URL(string: "https://console.cloud.google.com/")!)
                    Text("プロジェクトを作成または選択し、『APIとサービス → ライブラリ → Google Calendar API』を有効にします。")
                    Text("2. Google Auth Platform（旧：OAuth同意画面）で、アプリ名 MemoOnDesktop・サポートメール・連絡先を設定します。会社のGoogle Workspace内だけで使う場合は対象をInternal（内部）にできます。External（外部）でTesting（テスト）の場合は、自分のGoogleアカウントをTest usersに追加してください。")
                    Text("3. Data Access（データアクセス）で、次の読み取り専用スコープを設定します。予定とカレンダー一覧の読み取りだけを使います。")
                    Text("https://www.googleapis.com/auth/calendar.calendarlist.readonly\nhttps://www.googleapis.com/auth/calendar.events.readonly")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text("4. Clients（クライアント）→ Create client（クライアント作成）→ アプリの種類を『デスクトップ アプリ』にし、名前を MemoOnDesktop にします。作成後にJSONをダウンロードしてください。Webアプリ用・サービスアカウント用は使いません。Redirect URIの手動登録やAPIキーは不要です。")
                    Text("5. 上の『設定JSONを読み込む』でダウンロードしたファイルを選び、『Googleでログイン』を押します。標準ブラウザで対象アカウントを選択し、カレンダー一覧と予定の読み取りを許可します。完了したら本アプリに戻ってください。")
                    Text("6. 下の『表示するカレンダー』の選択ボタンから表示対象を選びます。カレンダー名・アカウントで検索でき、『選択済みのみ』でも絞り込めます。初回はメインカレンダーを選択します。タスク一覧の『予定』メニューで期間を選ぶと表示され、ビューに保存できます。")
                    Text("ExternalのTestingモードでは、Googleの仕様により通常7日で再ログインが必要になります。組織で連携やOAuthが制限されている場合、またはGoogleの検証が必要な場合は管理者と設定を確認してください。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Google公式：デスクトップアプリのOAuth設定", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2/native-app")!)
                }
                .font(.callout).padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
            }
            if store.access == .allowed {
                Divider()
                HStack {
                    Text("表示するカレンダー").font(.headline)
                    Spacer()
                    Button("一覧と予定を更新") { Task { await store.refresh(force: true) } }
                        .disabled(store.isRefreshing)
                }
                if store.calendars.isEmpty {
                    Text(store.isRefreshing ? "Googleからカレンダーを取得中…" : "カレンダーを取得できていません。上の案内やGoogle CloudのAPI設定を確認してください。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    CalendarSelectionPicker(calendars: store.calendars, selectedIDs: store.selectedIDs) { id, selected in
                        store.select(id, enabled: selected)
                    }
                }
            }
            Text("Googleから今日と明日から7日間の予定を1分ごと、アプリに戻ったとき、手動更新時に取得します。終日・繰り返し・日またぎに対応し、辞退・キャンセル済みは表示しません。予定の作成・変更・削除は行いません。")
                .font(.caption).foregroundStyle(.secondary)
            Text("認証設定と更新用トークンはMacのキーチェーンへ保存します。ログインは標準ブラウザで行い、応答はこのMac内だけの一時接続で受け取ります。予定の内容はメモリ上だけに保持します。連携解除はこのMacのトークンを削除し、設定JSONの情報は再ログイン用に残します。Google側でも失効させたい場合は、Googleアカウントのサードパーティ接続を取り消してください。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .task { await store.refresh() }
    }

    private func chooseClient() {
        let panel = NSOpenPanel()
        panel.title = "Googleのデスクトップ用OAuthクライアントJSONを選択"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 65536 else {
                throw GoogleCalendarError.message("設定JSONが大きすぎます。Google CloudからダウンロードしたクライアントJSONを選んでください。")
            }
            try store.importClientJSON(Data(contentsOf: url))
            importError = nil
        } catch {
            importError = (error as? GoogleCalendarError)?.localizedDescription ?? "設定JSONを読み込めませんでした。ファイルやキーチェーンのアクセス許可を確認してください。"
        }
    }
}
