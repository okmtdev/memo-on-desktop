import SwiftUI

struct IntegrationSettingsView: View {
    @EnvironmentObject private var integrations: IntegrationStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("連携設定").font(.largeTitle.bold())
                Text("Googleカレンダーの予定表示と、Slack・Notionの本文プレビューを設定できます。")
                    .foregroundStyle(.secondary)
                if let message = integrations.storageMessage {
                    Text(message).foregroundStyle(.red)
                }
                CalendarSettingsCard()
                IntegrationSetupCard(service: .slack)
                IntegrationSetupCard(service: .notion)
                Text("Slack・Notionは各1ワークスペース分を設定できます。認証情報はこのMacのキーチェーンに保存し、タスクデータには含めません。本文は『プレビュー』を押したときに公式APIから取得し、ディスクには保存しません。トークンは対応するサービスのAPIにだけ送信します。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("ローカルでの連携解除は保存済みトークンを削除します。トークン自体を失効させる場合はSlack・Notion側でも取り消してください。開発用ビルドの更新後、キーチェーンへのアクセス許可をmacOSから求められることがあります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .frame(minWidth: 660, minHeight: 580)
    }
}

private struct IntegrationSetupCard: View {
    let service: IntegrationService
    @EnvironmentObject private var integrations: IntegrationStore
    @State private var token = ""
    @State private var status: String?
    @State private var failed = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(service.name).font(.title2.bold())
                Spacer()
                Text(integrations.configured.contains(service) ? "設定済み" : "未設定")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if service == .slack { slackInstructions } else { notionInstructions }
            Divider()
            SecureField(service == .slack ? "User OAuth Token（xoxp-…）" : "Notionの内部インテグレーショントークン", text: $token)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(service.name)のトークン")
            HStack {
                Button("接続を確認して保存") { run { try await integrations.save(token, for: service) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                Button("保存済みの接続を確認") { run { try await integrations.test(service) } }
                    .disabled(!integrations.configured.contains(service) || busy)
                Button("連携を解除") {
                    do {
                        try integrations.disconnect(service)
                        token = ""
                        failed = false
                        status = "このMacの認証情報を削除しました。"
                    } catch {
                        failed = true
                        status = error.localizedDescription
                    }
                }
                .disabled(!integrations.configured.contains(service) || busy)
                if busy { ProgressView().controlSize(.small) }
            }
            if let status {
                Text(status).font(.callout).foregroundStyle(failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .onDisappear { token = "" }
    }

    private var slackInstructions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Link("1. Slackアプリの管理画面を開く", destination: URL(string: "https://api.slack.com/apps")!)
            Text("2. Create New App → From scratch を選択。名前を MemoOnDesktop にし、依頼が届くワークスペースを選びます。")
            Text("3. OAuth & Permissions → Scopes → User Token Scopes に、必要な読み取り権限を追加します。Bot Token Scopesではありません。")
            Text("channels:history  公開チャンネル\ngroups:history  参加中の非公開チャンネル\nim:history  ダイレクトメッセージ\nmpim:history  グループDM")
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Text("4. OAuth & Permissions の Install to Workspace（または Reinstall to Workspace）から自分のアカウントで許可します。会社で承認が必要なら管理者に申請します。")
            Text("5. 表示された User OAuth Token（xoxp-…）をコピーし、下の欄で保存します。Bot User OAuth Token（xoxb-…）やClient Secretは使いません。権限を変更した後は再インストールが必要です。")
            Text("6. Slackでメッセージの『リンクをコピー』を選び、タスクの関連URL欄に貼って『プレビュー』を押します。スレッド内の返信は、その返信自身のリンクを使います。")
            Text("この方式ではRedirect URL・Events・Socket Mode・書き込み権限は不要です。Token Rotationは有効化せず利用してください。失効した場合は新しいUser Tokenを登録し直します。Slackの取得回数制限に達した場合は、表示された待ち時間の後で再試行してください。")
                .font(.caption).foregroundStyle(.secondary)
            Text("新しく作成したSlack AppのUser OAuth TokenとWeb APIを使います。レガシーBot・Webhookは使用しないため、それらの社内利用禁止の影響は受けません。Slack Appのインストールと読み取り権限は社内ルールに沿って承認を受けてください。")
                .font(.caption).foregroundStyle(.secondary)
            Link("Slack公式：User Tokenとメッセージ取得", destination: URL(string: "https://docs.slack.dev/reference/methods/conversations.history/")!)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var notionInstructions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Link("1. NotionのDeveloper portalを開く", destination: URL(string: "https://www.notion.so/profile/integrations")!)
            Text("2. Developer portalの Build → Internal connections から Create a new connection（旧画面では新しいインテグレーション）を選びます。名前を MemoOnDesktop にし、対象ワークスペースを選びます。作成にはWorkspace Owner権限が必要です。作成できない場合はオーナーに依頼してください。")
            Text("3. Capabilitiesで Read content（コンテンツの読み取り）を有効にします。更新・挿入・コメント・ユーザー情報の権限は不要です。")
            Text("4. Configuration等に表示される Internal Integration Secret（内部インテグレーショントークン）をコピーし、下の欄で保存します。ntn_ または secret_ など、表示された値をそのまま使用します。")
            Text("5. 読みたいNotionページを開き、右上の『…』→『コネクト／Connections』→ 接続を追加 → MemoOnDesktop を選びます。Developer portalの Content access → Edit access でも対象を選べます。親ページに接続すると、その配下もアクセス対象になります。必要な範囲だけ接続してください。")
            Text("6. ページのリンクをタスクの関連URLに貼り、『プレビュー』を押します。接続確認は成功しても、ページを接続しないと本文は取得できません。404や権限エラーの場合は手順5を確認してください。")
            Text("notion.so / notion.site / notion.com のページURLに対応します。短縮URL・独自ドメインは元のページURLを使ってください。ページ先頭のテキストを抜粋し、入れ子やデータベース・画像・コメントは取得しません。")
                .font(.caption).foregroundStyle(.secondary)
            Link("Notion公式：内部インテグレーションの設定", destination: URL(string: "https://developers.notion.com/guides/get-started/internal-connections")!)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func run(_ operation: @escaping @MainActor () async throws -> String) {
        busy = true
        status = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                status = try await operation()
                token = ""
                failed = false
            } catch {
                failed = true
                status = (error as? IntegrationFailure)?.message ?? "通信できませんでした。ネットワークを確認して再試行してください。"
            }
        }
    }
}
