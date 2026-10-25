import AppKit
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// WebVault 服务装配点。
@MainActor
public enum WebVaultServices {
    public static var store = WebVaultStore(database: Database(url: AppEnvironment.databaseURL))

    public static func inject(store newStore: WebVaultStore) {
        store = newStore
    }
}

/// WebVault 主界面。
public struct WebVaultView: View {
    @State private var items: [WebItem] = []
    @State private var query = ""
    @State private var urlString = ""
    @State private var tagsText = ""
    @State private var statusMessage: String?
    @State private var showUnreadOnly = false
    @State private var detail: WebItem?

    public init() {}

    public var body: some View {
        ToolContainer("网页资料库", subtitle: "Web Vault · 收藏 · 正文提取 · 与资料库统一检索") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索（全文：标题/摘要/正文）", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await reload() } }
                        .onChange(of: query) { _, _ in Task { await reload() } }
                    Toggle("未读", isOn: $showUnreadOnly)
                        .toggleStyle(.button)
                    Button("导出 JSON…") { exportJSON() }
                }

                HStack {
                    TextField("https://… 粘贴链接收藏", text: $urlString)
                        .textFieldStyle(.roundedBorder)
                    TextField("标签（逗号分隔）", text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button("收藏") { Task { await add() } }
                        .disabled(urlString.isEmpty)
                }

                if let message = statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }

                itemList

                if let detail {
                    detailView(detail)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await reload() }
    }

    private var itemList: some View {
        GroupBox("收藏（\(items.count)）") {
            VStack(alignment: .leading, spacing: 8) {
                if items.isEmpty {
                    Text("暂无收藏").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.isRead ? "checkmark.circle" : "circle.dashed")
                            .foregroundStyle(item.isRead ? .green : .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout).lineLimit(1)
                            Text(item.url).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            if !item.excerpt.isEmpty {
                                Text(item.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        if item.fetchFailed {
                            Label("抓取失败", systemImage: "wifi.exclamationmark")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Button("打开") {
                            if let url = URL(string: item.url) {
                                NSWorkspace.shared.open(url)
                            }
                            markRead(item)
                        }
                        .buttonStyle(.link).font(.caption)
                        Button("正文") { detail = item }
                            .buttonStyle(.link).font(.caption)
                        Button("删除", role: .destructive) {
                            Task {
                                try? await WebVaultServices.store.delete(id: item.id)
                                await reload()
                            }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                    .padding(6)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    @ViewBuilder
    private func detailView(_ item: WebItem) -> some View {
        GroupBox("正文：\(item.title)") {
            VStack(alignment: .leading, spacing: 6) {
                if item.contentText.isEmpty {
                    Text("正文提取失败（动态页面或访问受限）。可打开网页人工阅读。")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    ScrollView {
                        Text(item.contentText)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                }
                HStack {
                    Button("复制正文") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.contentText, forType: .string)
                    }
                    .disabled(item.contentText.isEmpty)
                    Button("存入资料库") {
                        Task {
                            try? await VaultBridge.save(VaultBridge.Payload(
                                title: item.title,
                                content: item.contentText.isEmpty ? item.url : item.contentText,
                                tags: ["网页"] + item.tags))
                            statusMessage = "已存入资料库"
                        }
                    }
                    Spacer()
                    Button("关闭") { detail = nil }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - 动作

    private func reload() async {
        var list = (try? await WebVaultServices.store.search(query)) ?? []
        if showUnreadOnly {
            list = list.filter { !$0.isRead }
        }
        items = list
    }

    private func add() async {
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        statusMessage = "抓取中…"
        do {
            let (item, added) = try await WebVaultServices.store.add(url: urlString, tags: tags)
            if added {
                statusMessage = "已收藏：\(item.title)"
            } else {
                statusMessage = "该链接已收藏（去重识别）：\(item.title)"
            }
            urlString = ""
            tagsText = ""
        } catch {
            statusMessage = "收藏失败：\(String(describing: error))"
        }
        await reload()
    }

    private func markRead(_ item: WebItem) {
        Task {
            var updated = item
            updated.isRead = true
            try? await WebVaultServices.store.save(updated)
            await reload()
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "web-vault.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let all = (try? await WebVaultServices.store.all()) ?? []
                if let data = try? JSONEncoder().encode(all) {
                    try? data.write(to: url, options: .atomic)
                    statusMessage = "已导出 \(all.count) 条"
                }
            }
        }
    }
}

/// 跨模块桥（把网页正文存进 Recall Vault；由宿主注入，避免模块间直接依赖）。
@MainActor
public enum VaultBridge {
    public struct Payload: Sendable {
        public let title: String
        public let content: String
        public let tags: [String]
        public init(title: String, content: String, tags: [String]) {
            self.title = title
            self.content = content
            self.tags = tags
        }
    }

    public static var saveHandler: (Payload) async throws -> Void = { _ in
        throw DeskvanicError(.internalInconsistency, "资料库未就绪")
    }

    static func save(_ payload: Payload) async throws {
        try await saveHandler(payload)
    }
}
