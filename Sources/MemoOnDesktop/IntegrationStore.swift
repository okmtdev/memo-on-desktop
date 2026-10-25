import Combine
import Foundation
import Security

struct CredentialVault {
    private let service: String

    init(service: String = "local.memo-on-desktop.integrations") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func read(_ account: IntegrationService) throws -> String? {
        try read(account: account.rawValue)
    }

    func read(account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw IntegrationFailure(message: "キーチェーンの認証情報を読み出せませんでした（\(status)）。Macのロック解除やアクセス許可を確認してください。")
        }
        return token
    }

    func save(_ token: String, for account: IntegrationService) throws {
        try save(token, account: account.rawValue)
    }

    func save(_ token: String, account: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess {
            throw failure(status)
        }
    }

    func remove(_ account: IntegrationService) throws {
        try remove(account: account.rawValue)
    }

    func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private func failure(_ status: OSStatus) -> IntegrationFailure {
        IntegrationFailure(message: "キーチェーンの更新に失敗しました（\(status)）。アクセス許可を確認してください。")
    }
}

@MainActor
final class IntegrationStore: ObservableObject {
    @Published private(set) var configured: Set<IntegrationService> = []
    @Published private(set) var revision = UUID()
    @Published private(set) var storageMessage: String?
    private let vault = CredentialVault()
    private let api = IntegrationAPI()

    init() {
        for service in IntegrationService.allCases {
            do {
                if try vault.read(service) != nil { configured.insert(service) }
            } catch { storageMessage = error.localizedDescription }
        }
    }

    func save(_ token: String, for service: IntegrationService) async throws -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw IntegrationFailure(message: "トークンを空白なしで入力してください。")
        }
        if service == .slack && !token.hasPrefix("xoxp-") {
            throw IntegrationFailure(message: "Slackは xoxp- で始まるUser OAuth Tokenを使ってください。Bot TokenやApp-Level Tokenは対象外です。")
        }
        let account = try await api.validate(service, token: token)
        try vault.save(token, for: service)
        configured.insert(service)
        revision = UUID()
        storageMessage = nil
        return "\(account)の接続を確認し、キーチェーンに保存しました。"
    }

    func test(_ service: IntegrationService) async throws -> String {
        guard let token = try vault.read(service) else { throw missing(service) }
        let account = try await api.validate(service, token: token)
        return "\(account)に接続できました。本文の閲覧権限は対象URLのプレビューで確認してください。"
    }

    func disconnect(_ service: IntegrationService) throws {
        try vault.remove(service)
        configured.remove(service)
        revision = UUID()
    }

    func preview(_ service: IntegrationService, url: URL) async throws -> PreviewContent {
        guard let token = try vault.read(service) else { throw missing(service) }
        return try await api.preview(service, url: url, token: token)
    }

    private func missing(_ service: IntegrationService) -> IntegrationFailure {
        IntegrationFailure(message: "\(service.name)が未設定です。『連携設定』の手順に沿ってトークンを登録してください。")
    }
}
