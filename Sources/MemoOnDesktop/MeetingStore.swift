import AppKit
import Combine
import Foundation

enum MeetingAccess: Sendable { case notRequested, allowed, needsReconnect }

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var access: MeetingAccess = .notRequested
    @Published private(set) var calendars: [MeetingCalendar] = []
    @Published private(set) var meetings: [CalendarMeeting] = []
    @Published private(set) var selectedIDs: Set<String>
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var hasClientConfiguration = false
    @Published private(set) var updatedAt: Date?
    @Published private(set) var message: String?

    private struct Stored: Codable {
        var configuration: GoogleOAuthConfiguration
        var session: GoogleCalendarSession?
    }
    private let vault = CredentialVault()
    private let credentialAccount = "google-calendar.oauth.v1"
    private let api = GoogleCalendarAPI()
    private let oauth = GoogleOAuthFlow()
    private let defaults = UserDefaults(suiteName: "MemoOnDesktop") ?? .standard
    private let selectionKey = "memo-on-desktop.google-calendar.selected.v1"
    private let selectionInitializedKey = "memo-on-desktop.google-calendar.selectionInitialized.v1"
    private var configuration: GoogleOAuthConfiguration?
    private var session: GoogleCalendarSession?
    private var refreshAgain = false
    private var generation = UUID()
    private var lastAttempt: Date?
    private var retryAfter: Date?

    init() {
        selectedIDs = Set(defaults.stringArray(forKey: selectionKey) ?? [])
        do {
            if let value = try vault.read(account: credentialAccount) {
                let stored = try JSONDecoder().decode(Stored.self, from: Data(value.utf8))
                configuration = stored.configuration
                session = stored.session
                hasClientConfiguration = true
                access = stored.session == nil ? .notRequested : .allowed
            }
        } catch {
            message = "Googleの認証設定をキーチェーンから読み出せませんでした。設定JSONを読み込み直すか、キーチェーンへのアクセス許可を確認してください。"
        }
    }

    var hasAvailableSelection: Bool { calendars.contains { selectedIDs.contains($0.id) } }

    func importClientJSON(_ data: Data) throws {
        let config = try GoogleOAuthConfiguration.parse(data)
        try persist(configuration: config, session: nil)
        generation = UUID()
        configuration = config
        session = nil
        hasClientConfiguration = true
        access = .notRequested
        calendars = []
        meetings = []
        updatedAt = nil
        message = nil
        resetSelection()
    }

    func requestAccess() async {
        guard !isRequestingAccess, let configuration else { return }
        isRequestingAccess = true
        message = nil
        let revision = UUID()
        generation = revision
        defer { isRequestingAccess = false }
        do {
            let grant = try await oauth.authorize(configuration: configuration)
            let connected = try await api.exchange(grant, configuration: configuration)
            guard generation == revision else { return }
            try persist(configuration: configuration, session: connected)
            session = connected
            access = .allowed
            calendars = []
            meetings = []
            updatedAt = nil
            resetSelection()
            lastAttempt = nil
            retryAfter = nil
            NSApplication.shared.activate(ignoringOtherApps: true)
            Task { await refresh(force: true) }
        } catch is CancellationError {
            if generation == revision { message = "Googleログインをキャンセルしました。" }
        } catch {
            if generation == revision { message = safeMessage(error) }
        }
    }

    func cancelLogin() {
        generation = UUID()
        oauth.cancel()
        message = "Googleログインをキャンセルしました。"
    }

    func disconnect() throws {
        guard let configuration else { return }
        try persist(configuration: configuration, session: nil)
        generation = UUID()
        oauth.cancel()
        session = nil
        access = .notRequested
        calendars = []
        meetings = []
        updatedAt = nil
        message = nil
        resetSelection()
    }

    private func resetSelection() {
        selectedIDs = []
        defaults.removeObject(forKey: selectionKey)
        defaults.removeObject(forKey: selectionInitializedKey)
    }

    func select(_ id: String, enabled: Bool) {
        if enabled { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        defaults.set(selectedIDs.sorted(), forKey: selectionKey)
        defaults.set(true, forKey: selectionInitializedKey)
        meetings = []
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        guard access == .allowed, !isRequestingAccess else { return }
        if isRefreshing { refreshAgain = true; return }
        if let retryAfter, Date() < retryAfter { return }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 60 { return }
        isRefreshing = true
        var forceTokenRefresh = false
        var retriedUnauthorized = false
        defer {
            isRefreshing = false
            if refreshAgain {
                refreshAgain = false
                Task { await refresh(force: true) }
            }
        }
        repeat {
            refreshAgain = false
            let revision = generation
            guard var active = session else { return }
            lastAttempt = Date()
            do {
                if active.expiresAt <= Date() || forceTokenRefresh {
                    active = try await api.refresh(active)
                    guard generation == revision else { return }
                    try persist(configuration: active.configuration, session: active)
                    session = active
                    forceTokenRefresh = false
                }
                let available = try await api.calendars(token: active.accessToken)
                guard generation == revision else { return }
                calendars = available
                if !defaults.bool(forKey: selectionInitializedKey) {
                    selectedIDs = Set(available.filter(\.primary).map(\.id))
                    defaults.set(selectedIDs.sorted(), forKey: selectionKey)
                    defaults.set(true, forKey: selectionInitializedKey)
                }
                let selected = selectedIDs
                let now = Date()
                let interval = DateInterval(start: MeetingPeriod.today.interval(now: now).start, end: MeetingPeriod.upcoming.interval(now: now).end)
                var events: [CalendarMeeting] = []
                for calendar in available where selected.contains(calendar.id) {
                    events += try await api.events(calendar: calendar, interval: interval, token: active.accessToken)
                }
                guard generation == revision else { return }
                if selected == selectedIDs {
                    meetings = events
                    updatedAt = Date()
                    message = nil
                    retryAfter = nil
                } else { refreshAgain = true }
            } catch {
                guard generation == revision else { return }
                if let googleError = error as? GoogleCalendarError {
                    switch googleError {
                    case .reconnect:
                        if !retriedUnauthorized {
                            retriedUnauthorized = true
                            forceTokenRefresh = true
                            refreshAgain = true
                            continue
                        }
                        access = .needsReconnect
                        meetings = []
                        updatedAt = nil
                    case .rateLimit(let date): retryAfter = date
                    default: break
                    }
                }
                message = safeMessage(error)
                return
            }
        } while refreshAgain
    }

    private func persist(configuration: GoogleOAuthConfiguration, session: GoogleCalendarSession?) throws {
        let data = try JSONEncoder().encode(Stored(configuration: configuration, session: session))
        try vault.save(String(decoding: data, as: UTF8.self), account: credentialAccount)
    }

    private func safeMessage(_ error: Error) -> String {
        if let error = error as? GoogleCalendarError { return error.localizedDescription }
        if let error = error as? IntegrationFailure { return error.message }
        return "Googleに接続できませんでした。ネットワークやVPNの設定を確認して再試行してください。"
    }
}
