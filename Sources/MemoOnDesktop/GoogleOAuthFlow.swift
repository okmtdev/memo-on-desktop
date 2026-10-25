import AppKit
import CryptoKit
import Foundation
@preconcurrency import Network
import Security

struct GoogleOAuthProof: Sendable {
    let verifier: String
    let challenge: String
    let state: String

    init() throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw GoogleCalendarError.message("認証用の乱数を生成できませんでした。再試行してください。")
            }
            return Self.base64URL(Data(bytes))
        }
        verifier = try random()
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        state = try random()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func authorizationURL(clientID: String, redirectURI: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            "client_id": clientID, "redirect_uri": redirectURI, "response_type": "code",
            "scope": GoogleCalendarAPI.scopes.joined(separator: " "), "access_type": "offline",
            "prompt": "consent select_account", "state": state,
            "code_challenge": challenge, "code_challenge_method": "S256"
        ].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    static func callback(_ requestLine: String, expectedState: String) -> Result<String, GoogleCalendarError>? {
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/?"),
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])"), components.path == "/" else { return nil }
        let items = components.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states.first?.value == expectedState else { return nil }
        if items.contains(where: { $0.name == "error" }) {
            return .failure(.message("Googleでの認証がキャンセルまたは拒否されました。連携設定からやり直せます。"))
        }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty else { return nil }
        return .success(code)
    }
}

/// Receives Google's response on an ephemeral IPv4 loopback port only.
@MainActor
final class GoogleOAuthFlow {
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var result: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [NWConnection] = []
    private var expectedState = ""

    func authorize(configuration: GoogleOAuthConfiguration, timeoutDuration: Duration = .seconds(300),
                   openBrowser: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) async throws -> GoogleAuthorizationGrant {
        guard listener == nil else { throw GoogleCalendarError.message("Googleのログインを処理中です。") }
        let proof = try GoogleOAuthProof()
        expectedState = proof.state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        defer { cleanup() }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: timeoutDuration)
            guard !Task.isCancelled else { return }
            self?.fail(GoogleCalendarError.message("Googleログインの待機時間が終了しました。もう一度ログインしてください。"))
        }
        return try await withTaskCancellationHandler {
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.listener === listener else { return }
                        switch state {
                        case .ready:
                            if let port = listener.port?.rawValue {
                                self.ready?.resume(returning: port)
                                self.ready = nil
                            } else { self.fail(GoogleCalendarError.message("認証用ポートを準備できませんでした。")) }
                        case .failed:
                            self.fail(GoogleCalendarError.message("認証用のローカル接続を開始できませんでした。セキュリティ設定を確認してください。"))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        guard let self, self.listener === listener else { connection.cancel(); return }
                        self.receive(connection)
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
            try Task.checkCancellation()
            let redirectURI = "http://127.0.0.1:\(port)/"
            let code: String = try await withCheckedThrowingContinuation { continuation in
                result = continuation
                if !openBrowser(proof.authorizationURL(clientID: configuration.clientID, redirectURI: redirectURI)) {
                    fail(GoogleCalendarError.message("ブラウザを開けませんでした。標準ブラウザを確認して再試行してください。"))
                }
            }
            return GoogleAuthorizationGrant(code: code, redirectURI: redirectURI, verifier: proof.verifier)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { fail(CancellationError()) }

    private func receive(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        connections.append(connection)
        connection.start(queue: .global(qos: .userInitiated))
        receiveHeaders(connection, previous: Data())
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { connection.cancel() }
    }

    private func receiveHeaders(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, finished, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var bytes = previous
                if let data { bytes.append(data) }
                guard bytes.count <= 8192, error == nil else { self.close(connection); return }
                if let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") {
                    let state = self.expectedState
                    let callback = GoogleOAuthProof.callback(text.components(separatedBy: "\r\n").first ?? "", expectedState: state)
                    let status = callback == nil ? "400 Bad Request" : "200 OK"
                    let body = callback == nil ? "Invalid authentication response." : "Google連携の応答を受け付けました。この画面を閉じてMemoOnDesktopに戻ってください。"
                    let html = "<!doctype html><meta charset=utf-8><title>MemoOnDesktop</title><p>\(body)</p>"
                    let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n\(html)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                        Task { @MainActor in
                            self?.close(connection)
                            if self?.expectedState == state, let callback {
                                self?.result?.resume(with: callback.mapError { $0 as Error })
                                self?.result = nil
                            }
                        }
                    })
                } else if !finished { self.receiveHeaders(connection, previous: bytes) }
                else { self.close(connection) }
            }
        }
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
    }

    private func fail(_ error: Error) {
        ready?.resume(throwing: error)
        ready = nil
        result?.resume(throwing: error)
        result = nil
        cleanup()
    }

    private func cleanup() {
        timeout?.cancel()
        timeout = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections = []
        expectedState = ""
    }
}
