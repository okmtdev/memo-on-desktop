import Foundation
import LinkPresentation
import SwiftUI

enum TaskLink {
    static func parse(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func source(for url: URL) -> String {
        let host = url.host?.lowercased() ?? "リンク"
        if host == "slack.com" || host.hasSuffix(".slack.com") { return "Slack" }
        if host == "notion.so" || host.hasSuffix(".notion.so") ||
            host == "notion.site" || host.hasSuffix(".notion.site") ||
            host == "notion.com" || host.hasSuffix(".notion.com") { return "Notion" }
        return host
    }
}

struct TaskLinkView: View {
    let url: URL
    @State private var showingPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Link(destination: url) {
                    Label(TaskLink.source(for: url), systemImage: "arrow.up.right.square")
                }
                .help(url.absoluteString)
                Button(showingPreview ? "プレビューを閉じる" : "プレビュー") {
                    showingPreview.toggle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))

            if showingPreview {
                LinkPreview(url: url)
            }
        }
    }
}

private struct LinkPreview: View {
    let url: URL
    @EnvironmentObject private var integrations: IntegrationStore
    @Environment(\.openWindow) private var openWindow
    @State private var content: PreviewContent?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isLoading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("ページ情報を取得中…")
                }
            } else if let content {
                Text(content.title)
                    .fontWeight(.medium)
                    .lineLimit(3)
                if !content.body.isEmpty {
                    ScrollView {
                        Text(content.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: min(CGFloat(content.body.count / 45 + 1) * 16, 140))
                }
                if let note = content.note {
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text(errorMessage ?? "プレビューを取得できませんでした")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if ["Slack", "Notion"].contains(TaskLink.source(for: url)) {
                        Button("連携設定を開く") { openWindow(id: "integrations") }
                    }
                    Button("再試行") { attempt += 1 }
                }
            }
            Text(url.absoluteString)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .task(id: "\(url.absoluteString)-\(integrations.revision)-\(attempt)") { await fetch() }
    }

    @MainActor
    private func fetch() async {
        isLoading = true
        content = nil
        errorMessage = nil
        let source = TaskLink.source(for: url)
        if source == "Slack" || source == "Notion" {
            do {
                let result = try await integrations.preview(source == "Slack" ? .slack : .notion, url: url)
                guard !Task.isCancelled else { return }
                content = result
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = (error as? IntegrationFailure)?.message ?? "通信できませんでした。ネットワークを確認して再試行してください。"
            }
            isLoading = false
            return
        }
        let provider = LPMetadataProvider()
        provider.timeout = 8
        provider.shouldFetchSubresources = false
        defer { provider.cancel() }
        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            guard !Task.isCancelled else { return }
            let fetched = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let fetched, !fetched.isEmpty {
                content = PreviewContent(title: fetched, body: "")
            }
        } catch {
            // The original URL stays usable when offline or behind a login.
        }
        isLoading = false
    }
}
