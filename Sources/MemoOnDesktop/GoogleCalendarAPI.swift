import Foundation

struct GoogleOAuthConfiguration: Codable, Sendable {
    let clientID: String
    let clientSecret: String

    static func parse(_ data: Data) throws -> Self {
        struct Download: Decodable {
            struct Installed: Decodable { var client_id: String; var client_secret: String? }
            var installed: Installed?
        }
        guard let installed = try? JSONDecoder().decode(Download.self, from: data).installed,
              installed.client_id.hasSuffix(".apps.googleusercontent.com") else {
            throw GoogleCalendarError.message("デスクトップアプリ用OAuthクライアントのJSONを選択してください。Webアプリやサービスアカウント用のJSONは使えません。")
        }
        return Self(clientID: installed.client_id, clientSecret: installed.client_secret ?? "")
    }
}

struct GoogleCalendarSession: Codable, Sendable {
    var configuration: GoogleOAuthConfiguration
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

struct GoogleAuthorizationGrant: Sendable {
    let code: String
    let redirectURI: String
    let verifier: String
}

enum GoogleCalendarError: LocalizedError {
    case message(String)
    case reconnect
    case rateLimit(Date)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .reconnect: return "Googleの認証が失効しています。連携設定からGoogleにログインし直してください。"
        case .rateLimit(let date): return "Googleの取得回数制限です。\(date.formatted(date: .omitted, time: .shortened))以降に再試行してください。"
        }
    }
}

private final class GoogleNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GoogleCalendarAPI: Sendable {
    static let scopes = ["https://www.googleapis.com/auth/calendar.calendarlist.readonly", "https://www.googleapis.com/auth/calendar.events.readonly"]
    let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        self.session = session ?? URLSession(configuration: config, delegate: GoogleNoRedirects(), delegateQueue: nil)
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let text = values.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    private struct Token: Decodable {
        var access_token: String
        var expires_in: Double
        var refresh_token: String?
        var scope: String?
    }

    func exchange(_ grant: GoogleAuthorizationGrant, configuration: GoogleOAuthConfiguration) async throws -> GoogleCalendarSession {
        let token = try await tokenRequest(["grant_type": "authorization_code", "code": grant.code,
            "redirect_uri": grant.redirectURI, "code_verifier": grant.verifier,
            "client_id": configuration.clientID, "client_secret": configuration.clientSecret])
        if let scope = token.scope, !Set(Self.scopes).isSubset(of: Set(scope.split(separator: " ").map(String.init))) {
            throw GoogleCalendarError.message("カレンダー一覧と予定の読み取り権限を両方許可して、Googleにログインし直してください。")
        }
        guard let refresh = token.refresh_token, !refresh.isEmpty else {
            throw GoogleCalendarError.message("継続利用の認証情報を取得できませんでした。Googleアカウントの接続済みアプリから本アプリの連携を取り消し、ログインし直してください。")
        }
        return GoogleCalendarSession(configuration: configuration, accessToken: token.access_token, refreshToken: refresh,
                                     expiresAt: Date().addingTimeInterval(max(0, token.expires_in - 60)))
    }

    func refresh(_ stored: GoogleCalendarSession) async throws -> GoogleCalendarSession {
        let token = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": stored.refreshToken,
            "client_id": stored.configuration.clientID, "client_secret": stored.configuration.clientSecret])
        return GoogleCalendarSession(configuration: stored.configuration, accessToken: token.access_token,
            refreshToken: token.refresh_token ?? stored.refreshToken,
            expiresAt: Date().addingTimeInterval(max(0, token.expires_in - 60)))
    }

    private func tokenRequest(_ values: [String: String]) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(values.filter { $0.key != "client_secret" || !$0.value.isEmpty })
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if object?["error"] as? String == "invalid_client" {
                throw GoogleCalendarError.message("OAuthクライアント設定を確認してください。Google Cloudから新しいデスクトップ用JSONを取得し、読み込み直してください。")
            }
            throw GoogleCalendarError.reconnect
        }
        guard (200..<300).contains(status) else { throw GoogleCalendarError.message("Googleの認証サーバーに接続できませんでした。しばらく待って再試行してください。") }
        return try JSONDecoder().decode(Token.self, from: data)
    }

    func calendars(token: String) async throws -> [MeetingCalendar] {
        var result: [MeetingCalendar] = []
        var page: String?
        var seenPages = Set<String>()
        repeat {
            var query = ["maxResults": "250", "minAccessRole": "reader", "showHidden": "true",
                         "fields": "items(id,summary,summaryOverride,primary,timeZone,accessRole,deleted),nextPageToken"]
            query["pageToken"] = page
            let response = try await get(path: "users/me/calendarList", query: query, token: token)
            for item in response["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String, item["deleted"] as? Bool != true else { continue }
                result.append(MeetingCalendar(id: id, title: item["summaryOverride"] as? String ?? item["summary"] as? String ?? id,
                    account: id, primary: item["primary"] as? Bool ?? false, timeZone: item["timeZone"] as? String))
            }
            page = response["nextPageToken"] as? String
            if let page, !seenPages.insert(page).inserted { throw GoogleCalendarError.message("カレンダー一覧を最後まで取得できませんでした。再試行してください。") }
        } while page?.isEmpty == false
        return result.sorted { $0.primary != $1.primary ? $0.primary : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func events(calendar: MeetingCalendar, interval: DateInterval, token: String) async throws -> [CalendarMeeting] {
        let encoded = calendar.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let formatter = ISO8601DateFormatter()
        var result: [CalendarMeeting] = []
        var page: String?
        var seenPages = Set<String>()
        repeat {
            var query = ["timeMin": formatter.string(from: interval.start), "timeMax": formatter.string(from: interval.end),
                         "singleEvents": "true", "orderBy": "startTime", "showDeleted": "false", "maxResults": "250",
                         "timeZone": TimeZone.current.identifier,
                         "fields": "items(id,summary,status,start,end,location,hangoutLink,htmlLink,conferenceData(entryPoints),attendees(self,responseStatus)),nextPageToken"]
            query["pageToken"] = page
            let response = try await get(path: "calendars/\(encoded)/events", query: query, token: token)
            for item in response["items"] as? [[String: Any]] ?? [] {
                if let meeting = Self.meeting(item, calendar: calendar), meeting.overlaps(interval) { result.append(meeting) }
            }
            page = response["nextPageToken"] as? String
            if let page, !seenPages.insert(page).inserted { throw GoogleCalendarError.message("予定を最後まで取得できませんでした。再試行してください。") }
        } while page?.isEmpty == false
        return result
    }

    static func meeting(_ item: [String: Any], calendar: MeetingCalendar, localTimeZone: TimeZone = .current) -> CalendarMeeting? {
        guard item["status"] as? String != "cancelled", let id = item["id"] as? String,
              !((item["attendees"] as? [[String: Any]] ?? []).contains { $0["self"] as? Bool == true && $0["responseStatus"] as? String == "declined" }),
              let start = item["start"] as? [String: Any], let end = item["end"] as? [String: Any],
              let startDate = parseTime(start, fallbackTimeZone: calendar.timeZone, localTimeZone: localTimeZone),
              let endDate = parseTime(end, fallbackTimeZone: calendar.timeZone, localTimeZone: localTimeZone) else { return nil }
        let entries = (item["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] ?? []
        let video = entries.first { $0["entryPointType"] as? String == "video" }?["uri"] as? String
        let url = [item["hangoutLink"] as? String, video, item["htmlLink"] as? String].compactMap { $0 }.compactMap(URL.init(string:)).compactMap(MeetingList.webLink).first
        let title = item["summary"] as? String
        return CalendarMeeting(id: "\(calendar.id)|\(id)", title: title?.isEmpty == false ? title! : "予定あり",
            calendarTitle: calendar.title, start: startDate, end: endDate, allDay: start["date"] != nil,
            location: item["location"] as? String, link: url)
    }

    private static func parseTime(_ value: [String: Any], fallbackTimeZone: String?, localTimeZone: TimeZone) -> Date? {
        if let date = value["date"] as? String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = localTimeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: date)
        }
        guard let text = value["dateTime"] as? String else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: value["timeZone"] as? String ?? fallbackTimeZone ?? "") ?? localTimeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private func get(path: String, query: [String: String], token: String) async throws -> [String: Any] {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/\(path)")!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleCalendarError.message("Googleからの応答を確認できませんでした。") }
        if http.statusCode == 401 { throw GoogleCalendarError.reconnect }
        if http.statusCode == 429 {
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
            throw GoogleCalendarError.rateLimit(Date().addingTimeInterval(max(1, seconds)))
        }
        if http.statusCode == 403 {
            throw GoogleCalendarError.message("Google Calendar APIが無効、読み取り権限の不足、組織による制限、または利用上限の可能性があります。連携設定の手順とGoogle CloudのAPI設定を確認してください。")
        }
        if http.statusCode == 404 { throw GoogleCalendarError.message("選択したカレンダーが見つかりません。設定でカレンダーを選び直してください。") }
        guard (200..<300).contains(http.statusCode), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleCalendarError.message("Googleから予定を取得できませんでした。再試行してください。")
        }
        return object
    }
}
