import Foundation

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main
struct IntegrationChecks {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let api = IntegrationAPI(session: URLSession(configuration: config))
        let url = URL(string: "https://team.slack.com/archives/C123/p1700000000123456")!
        assert(SlackMessageLink(url: url)?.timestamp == "1700000000.123456")
        assert(SlackMessageLink(url: URL(string: "https://evil.example/archives/C123/p1700000000123456")!) == nil)
        assert(SlackMessageLink(url: URL(string: "https://team.slack.com/archives/C123/not-a-message")!) == nil)
        assert(TaskLink.source(for: URL(string: "https://slack.com.evil.example")!) != "Slack")
        assert(IntegrationAPI.notionPageID(URL(string: "https://app.notion.com/p/Title-123456781234123412341234567890ab?v=other")!) == "123456781234123412341234567890ab")
        assert(IntegrationAPI.notionPageID(URL(string: "https://team.notion.site/title-12345678-1234-1234-1234-1234567890ab")!) == "12345678-1234-1234-1234-1234567890ab")
        assert(IntegrationAPI.notionPageID(URL(string: "https://www.notion.so/no-page-id")!) == nil)

        MockProtocol.handler = { request in
            assert(request.url?.path == "/api/auth.test")
            return (200, [:], #"{"ok":true,"team":"Fixture Workspace"}"#)
        }
        let slackAccount = try await api.validate(.slack, token: "fixture")
        assert(slackAccount == "Fixture Workspace")
        MockProtocol.handler = { request in
            assert(request.url?.path == "/v1/users/me")
            return (200, [:], #"{"object":"user","type":"bot"}"#)
        }
        let notionAccount = try await api.validate(.notion, token: "fixture")
        assert(notionAccount == "Notion")
        MockProtocol.handler = { _ in (401, [:], "{}") }
        do {
            _ = try await api.validate(.notion, token: "fixture")
            fatalError("Expected invalid token failure")
        } catch let error as IntegrationFailure { assert(error.message.contains("認証")) }

        MockProtocol.handler = { request in
            assert(request.url?.host == "slack.com")
            assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
            assert(request.url?.path == "/api/conversations.history")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            assert(query.contains(URLQueryItem(name: "latest", value: "1700000000.123456")))
            return (200, [:], #"{"ok":true,"messages":[{"ts":"1700000000.123456","text":"Please check <https://example.com|the request> &amp; reply"}]}"#)
        }
        let slack = try await api.preview(.slack, url: url, token: "fixture")
        assert(slack.body == "Please check the request (https://example.com) & reply")

        let replyURL = URL(string: "https://team.slack.com/archives/C123/p1700000000123456?thread_ts=1699999999.123456")!
        MockProtocol.handler = { request in
            assert(request.url?.path == "/api/conversations.replies")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            assert(query.contains(URLQueryItem(name: "ts", value: "1699999999.123456")))
            return (200, [:], #"{"ok":true,"messages":[{"ts":"1699999999.123456","text":"wrong parent"},{"ts":"1700000000.123456","text":"right reply"}]}"#)
        }
        let reply = try await api.preview(.slack, url: replyURL, token: "fixture")
        assert(reply.body == "right reply")

        MockProtocol.handler = { _ in (200, [:], #"{"ok":false,"error":"missing_scope"}"#) }
        do {
            _ = try await api.preview(.slack, url: url, token: "fixture")
            fatalError("Expected missing scope failure")
        } catch let error as IntegrationFailure { assert(error.message.contains("権限")) }

        MockProtocol.handler = { _ in (429, ["Retry-After": "60"], "{}") }
        do {
            _ = try await api.preview(.slack, url: url, token: "fixture")
            fatalError("Expected rate limit failure")
        } catch let error as IntegrationFailure { assert(error.message.contains("60秒")) }

        MockProtocol.handler = { request in
            assert(request.url?.host == "api.notion.com")
            assert(request.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11")
            assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
            if request.url!.path.hasPrefix("/v1/pages/") {
                return (200, [:], #"{"properties":{"Name":{"type":"title","title":[{"plain_text":"依頼ページ"}]}}}"#)
            }
            assert(request.url!.path.hasSuffix("/children"))
            return (200, [:], #"{"results":[{"type":"paragraph","paragraph":{"rich_text":[{"plain_text":"依頼の本文"}]}},{"type":"heading_2","heading_2":{"rich_text":[{"text":{"content":"詳細"}}]}}]}"#)
        }
        let notionURL = URL(string: "https://www.notion.so/Title-123456781234123412341234567890ab")!
        let notion = try await api.preview(.notion, url: notionURL, token: "fixture")
        assert(notion.title == "依頼ページ" && notion.body == "依頼の本文\n詳細")

        MockProtocol.handler = { _ in (404, [:], "{}") }
        do {
            _ = try await api.preview(.notion, url: notionURL, token: "fixture")
            fatalError("Expected permission failure")
        } catch let error as IntegrationFailure { assert(error.message.contains("コネクト")) }

        let namespace = "local.memo-on-desktop.tests.\(UUID().uuidString)"
        let vault = CredentialVault(service: namespace)
        defer { try? vault.remove(.slack) }
        let initiallyStored = try vault.read(.slack)
        assert(initiallyStored == nil)
        try vault.save("fixture-first", for: .slack)
        let stored = try CredentialVault(service: namespace).read(.slack)
        assert(stored == "fixture-first")
        try vault.save("fixture-updated", for: .slack)
        let updated = try vault.read(.slack)
        assert(updated == "fixture-updated")
        try vault.remove(.slack)
        let removed = try vault.read(.slack)
        assert(removed == nil)
        print("PASS: Slack links/messages/replies, Notion IDs/content, API headers, scopes/rate limits/permissions, Keychain persistence/update/removal")
    }
}
