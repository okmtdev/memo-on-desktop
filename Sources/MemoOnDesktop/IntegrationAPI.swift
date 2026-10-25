import Foundation

struct PreviewContent: Sendable {
    var title: String
    var body: String
    var note: String? = nil
}

enum IntegrationService: String, CaseIterable, Identifiable, Sendable {
    case slack, notion
    var id: String { rawValue }
    var name: String { self == .slack ? "Slack" : "Notion" }
}

struct IntegrationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SlackMessageLink: Equatable {
    let channel: String
    let timestamp: String
    let thread: String?

    init?(url: URL) {
        guard TaskLink.source(for: url) == "Slack" else { return nil }
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "archives"), parts.count > index + 2 else { return nil }
        let channel = parts[index + 1]
        let raw = parts[index + 2]
        guard channel.range(of: "^[A-Z][A-Z0-9]+$", options: .regularExpression) != nil,
              raw.range(of: "^p[0-9]{16,}$", options: .regularExpression) != nil else { return nil }
        let digits = String(raw.dropFirst())
        self.channel = channel
        timestamp = String(digits.dropLast(6)) + "." + digits.suffix(6)
        let thread = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "thread_ts" })?.value
        self.thread = thread.flatMap {
            $0.range(of: "^[0-9]+\\.[0-9]{6}$", options: .regularExpression) != nil ? $0 : nil
        }
    }
}

// Never forward an Authorization header to a redirected host.
private final class NoAPIRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct IntegrationAPI: Sendable {
    let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        self.session = session ?? URLSession(configuration: configuration, delegate: NoAPIRedirects(), delegateQueue: nil)
    }

    func validate(_ service: IntegrationService, token: String) async throws -> String {
        if service == .slack {
            let result = try await slack("auth.test", token: token)
            return result["team"] as? String ?? "Slack"
        }
        _ = try await notion("users/me", token: token)
        return "Notion"
    }

    func preview(_ service: IntegrationService, url: URL, token: String) async throws -> PreviewContent {
        switch service {
        case .slack: return try await slackPreview(url: url, token: token)
        case .notion: return try await notionPreview(url: url, token: token)
        }
    }

    private func slackPreview(url: URL, token: String) async throws -> PreviewContent {
        guard let link = SlackMessageLink(url: url) else {
            throw IntegrationFailure(message: "Slackでメッセージの『リンクをコピー』を選び、/archives/…/p… 形式のURLを貼ってください。")
        }
        var query = ["channel": link.channel, "oldest": link.timestamp,
                     "latest": link.timestamp, "inclusive": "true", "limit": "1"]
        let method: String
        if let thread = link.thread, thread != link.timestamp {
            method = "conversations.replies"
            query["ts"] = thread
        } else {
            method = "conversations.history"
        }
        let result = try await slack(method, token: token, query: query)
        let messages = result["messages"] as? [[String: Any]] ?? []
        guard let message = messages.first(where: { $0["ts"] as? String == link.timestamp }) else {
            throw IntegrationFailure(message: "メッセージが見つかりません。削除済み、閲覧権限、ワークスペース、スレッドURLを確認してください。")
        }
        var text = message["text"] as? String ?? ""
        if text.isEmpty {
            text = (message["attachments"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        text = Self.slackPlainText(text)
        return PreviewContent(title: "Slackのメッセージ", body: text.isEmpty ? "テキストのないメッセージです。添付はリンクから開いてください。" : String(text.prefix(2400)),
                              note: "このメッセージの本文を表示しています（最大2,400文字）。添付・スレッド全体はリンクから開けます。")
    }

    static func slackPlainText(_ text: String) -> String {
        text.replacingOccurrences(of: "<([^>|]+)\\|([^>]+)>", with: "$2 ($1)", options: .regularExpression)
            .replacingOccurrences(of: "<(https?://[^>]+)>", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func notionPageID(_ url: URL) -> String? {
        guard TaskLink.source(for: url) == "Notion" else { return nil }
        let path = url.lastPathComponent
        guard let range = path.range(of: "([0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$", options: .regularExpression) else { return nil }
        return String(path[range])
    }

    static func richText(_ value: Any?) -> String {
        (value as? [[String: Any]] ?? []).map {
            $0["plain_text"] as? String ?? ($0["text"] as? [String: Any])?["content"] as? String ?? ""
        }.joined()
    }

    private func notionPreview(url: URL, token: String) async throws -> PreviewContent {
        guard let id = Self.notionPageID(url) else {
            throw IntegrationFailure(message: "NotionのページURLを貼ってください。短縮URLや独自ドメインは、元の notion.so / notion.site / notion.com のURLを使ってください。")
        }
        let page = try await notion("pages/\(id)", token: token)
        let properties = page["properties"] as? [String: [String: Any]] ?? [:]
        let titleProperty = properties.values.first { $0["type"] as? String == "title" }
        let title = Self.richText(titleProperty?["title"])
        let blocks = try await notion("blocks/\(id)/children?page_size=30", token: token)
        var lines: [String] = []
        for block in blocks["results"] as? [[String: Any]] ?? [] {
            guard let type = block["type"] as? String, let content = block[type] as? [String: Any] else { continue }
            var text = Self.richText(content["rich_text"])
            if text.isEmpty { text = content["title"] as? String ?? "" }
            if !text.isEmpty { lines.append(text) }
        }
        return PreviewContent(title: title.isEmpty ? "Notionのページ" : title,
                              body: lines.isEmpty ? "先頭に表示できるテキストがありません。リンクからページを開いてください。" : String(lines.joined(separator: "\n").prefix(2400)),
                              note: "先頭30ブロック・最大2,400文字の抜粋です。入れ子・画像・データベース・コメントはリンクから開いてください。")
    }

    private func slack(_ method: String, token: String, query: [String: String] = [:]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://slack.com/api/\(method)")!
        components.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        let result = try await request(components.url!, token: token, service: .slack)
        guard result["ok"] as? Bool == true else {
            let code = result["error"] as? String ?? "unknown"
            let message: String
            switch code {
            case "invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive":
                message = "Slackの認証が無効・期限切れです。連携設定でUser OAuth Tokenを登録し直してください。"
            case "missing_scope", "not_allowed_token_type":
                message = "Slackの権限が不足しています。User Token Scopesの履歴権限を追加し、再インストールしてUser OAuth Tokenを登録し直してください。"
            case "channel_not_found", "not_in_channel", "thread_not_found":
                message = "Slackの対象を閲覧できません。参加状況と、トークンのワークスペースを確認してください。"
            case "ratelimited": message = "Slackの取得回数制限に達しました。少し待って再試行してください。"
            default: message = "Slackからメッセージを取得できませんでした。連携設定とURLを確認してください。"
            }
            throw IntegrationFailure(message: message)
        }
        return result
    }

    private func notion(_ path: String, token: String) async throws -> [String: Any] {
        try await request(URL(string: "https://api.notion.com/v1/\(path)")!, token: token, service: .notion)
    }

    private func request(_ url: URL, token: String, service: IntegrationService) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if service == .notion { request.setValue("2026-03-11", forHTTPHeaderField: "Notion-Version") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw IntegrationFailure(message: "サーバーの応答を確認できませんでした。") }
        switch response.statusCode {
        case 200..<300: break
        case 401: throw IntegrationFailure(message: "\(service.name)の認証が無効です。連携設定でトークンを登録し直してください。")
        case 403, 404: throw IntegrationFailure(message: "\(service.name)の閲覧権限がありません。Notionはページの『コネクト』への追加、Slackはワークスペースと参加状況を確認してください。")
        case 429:
            let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw IntegrationFailure(message: "取得回数の制限です。\(delay.map { "約\($0)秒" } ?? "しばらく")待って再試行してください。")
        default: throw IntegrationFailure(message: "\(service.name)から取得できませんでした（HTTP \(response.statusCode)）。")
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw IntegrationFailure(message: "サーバーの応答形式が予期したものと異なります。") }
        return result
    }
}
