import CryptoKit
import Foundation

private func formBody(_ request: URLRequest) -> String {
    if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        result.append(contentsOf: buffer.prefix(count))
    }
    return String(decoding: result, as: UTF8.self)
}

private final class GoogleMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, headers, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main
struct GoogleCalendarChecks {
    @MainActor
    static func main() async throws {
        let config = try GoogleOAuthConfiguration.parse(Data(#"{"installed":{"client_id":"fixture.apps.googleusercontent.com","client_secret":"fixture-secret"}}"#.utf8))
        do {
            _ = try GoogleOAuthConfiguration.parse(Data(#"{"web":{"client_id":"fixture.apps.googleusercontent.com"}}"#.utf8))
            fatalError("Web client should be rejected")
        } catch is GoogleCalendarError { }
        let proof = try GoogleOAuthProof()
        assert(proof.verifier.count == 43 && proof.state.count == 43 && proof.verifier != proof.state)
        assert(proof.challenge == GoogleOAuthProof.base64URL(Data(SHA256.hash(data: Data(proof.verifier.utf8)))))
        let auth = proof.authorizationURL(clientID: config.clientID, redirectURI: "http://127.0.0.1:12345/")
        let authItems = URLComponents(url: auth, resolvingAgainstBaseURL: false)!.queryItems!
        assert(auth.host == "accounts.google.com")
        assert(authItems.contains(URLQueryItem(name: "code_challenge_method", value: "S256")))
        assert(authItems.contains(URLQueryItem(name: "access_type", value: "offline")))
        assert(authItems.contains(URLQueryItem(name: "scope", value: GoogleCalendarAPI.scopes.joined(separator: " "))))
        assert(GoogleOAuthProof.callback("GET /?code=fixture&state=wrong HTTP/1.1", expectedState: proof.state) == nil)
        assert(GoogleOAuthProof.callback("GET /?code=a&code=b&state=\(proof.state) HTTP/1.1", expectedState: proof.state) == nil)
        assert(GoogleOAuthProof.callback("GET /other?code=a&state=\(proof.state) HTTP/1.1", expectedState: proof.state) == nil)
        if case .failure? = GoogleOAuthProof.callback("GET /?error=access_denied&state=\(proof.state) HTTP/1.1", expectedState: proof.state) { } else { fatalError("Expected denial") }

        // Exercise a real loopback listener without opening a browser or contacting Google.
        let flow = GoogleOAuthFlow()
        var callbackTask: Task<Void, Error>?
        let grant = try await flow.authorize(configuration: config, timeoutDuration: .seconds(5)) { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = query.first { $0.name == "redirect_uri" }!.value!
            let state = query.first { $0.name == "state" }!.value!
            assert(URL(string: redirect)!.host == "127.0.0.1")
            callbackTask = Task {
                let wrong = URL(string: "\(redirect)?code=ignored&state=wrong")!
                let (_, badResponse) = try await URLSession.shared.data(from: wrong)
                assert((badResponse as? HTTPURLResponse)?.statusCode == 400)
                let callback = URL(string: "\(redirect)?code=local-fixture&state=\(state)")!
                let (_, response) = try await URLSession.shared.data(from: callback)
                assert((response as? HTTPURLResponse)?.statusCode == 200)
            }
            return true
        }
        try await callbackTask?.value
        assert(grant.code == "local-fixture" && grant.verifier.count == 43)
        let cancelled = Task { @MainActor in
            try await flow.authorize(configuration: config, timeoutDuration: .seconds(5)) { _ in
                Task { @MainActor in flow.cancel() }
                return true
            }
        }
        do { _ = try await cancelled.value; fatalError("Expected cancellation") }
        catch is CancellationError { }

        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [GoogleMockProtocol.self]
        let api = GoogleCalendarAPI(session: URLSession(configuration: settings))
        GoogleMockProtocol.handler = { request in
            assert(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
            assert(request.httpMethod == "POST")
            let body = formBody(request)
            assert(body.contains("code_verifier="))
            return (200, [:], "{\"access_token\":\"access-fixture\",\"expires_in\":3600,\"refresh_token\":\"refresh-fixture\",\"scope\":\"\(GoogleCalendarAPI.scopes.joined(separator: " "))\"}")
        }
        let session = try await api.exchange(grant, configuration: config)
        assert(session.refreshToken == "refresh-fixture")
        GoogleMockProtocol.handler = { request in
            let body = formBody(request)
            assert(body.contains("grant_type=refresh_token"))
            return (200, [:], #"{"access_token":"updated-access","expires_in":3600}"#)
        }
        let refreshed = try await api.refresh(session)
        assert(refreshed.accessToken == "updated-access" && refreshed.refreshToken == "refresh-fixture")
        GoogleMockProtocol.handler = { request in
            assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-fixture")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if items.contains(URLQueryItem(name: "pageToken", value: "next")) {
                return (200, [:], #"{"items":[{"id":"shared@example.com","summary":"Shared","timeZone":"Asia/Tokyo"}]}"#)
            }
            return (200, [:], #"{"items":[{"id":"primary@example.com","summary":"My calendar","primary":true}],"nextPageToken":"next"}"#)
        }
        let calendars = try await api.calendars(token: "access-fixture")
        assert(calendars.count == 2 && calendars.first!.primary)
        GoogleMockProtocol.handler = { request in
            assert(request.url!.path.contains("/events"))
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            assert(items.contains(URLQueryItem(name: "singleEvents", value: "true")))
            assert(items.contains(URLQueryItem(name: "orderBy", value: "startTime")))
            return (200, [:], #"{"items":[{"id":"instance1","summary":"Meeting","start":{"dateTime":"2026-10-23T09:00:00+09:00"},"end":{"dateTime":"2026-10-23T10:00:00+09:00"},"hangoutLink":"https://meet.google.com/fixture"}]}"#)
        }
        let iso = ISO8601DateFormatter()
        let interval = DateInterval(start: iso.date(from: "2026-10-23T00:00:00+09:00")!, end: iso.date(from: "2026-10-24T00:00:00+09:00")!)
        let events = try await api.events(calendar: calendars[0], interval: interval, token: "access-fixture")
        assert(events.count == 1 && events[0].link?.host == "meet.google.com")
        let allDay: [String: Any] = ["id": "all-day", "start": ["date": "2026-10-23"], "end": ["date": "2026-10-24"]]
        let parsed = GoogleCalendarAPI.meeting(allDay, calendar: calendars[0], localTimeZone: TimeZone(identifier: "Asia/Tokyo")!)!
        assert(parsed.allDay && parsed.start == interval.start && parsed.end == interval.end)
        var declined = allDay
        declined["attendees"] = [["self": true, "responseStatus": "declined"]]
        assert(GoogleCalendarAPI.meeting(declined, calendar: calendars[0]) == nil)
        var deleted = allDay
        deleted["status"] = "cancelled"
        assert(GoogleCalendarAPI.meeting(deleted, calendar: calendars[0]) == nil)
        GoogleMockProtocol.handler = { _ in (401, [:], "{}") }
        do { _ = try await api.calendars(token: "fixture"); fatalError("Expected reconnect") }
        catch GoogleCalendarError.reconnect { }
        GoogleMockProtocol.handler = { _ in (429, ["Retry-After": "60"], "{}") }
        do { _ = try await api.calendars(token: "fixture"); fatalError("Expected rate limit") }
        catch GoogleCalendarError.rateLimit(let date) { assert(date.timeIntervalSinceNow > 50) }
        print("PASS: desktop JSON, PKCE/state, real loopback callback/rejection/cancellation, OAuth exchange/refresh, calendar pagination, recurring-event query, timezones/all-day, declined/cancelled events, auth/rate-limit errors")
    }
}
