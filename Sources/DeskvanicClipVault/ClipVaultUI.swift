import AppKit
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// ClipVault 主界面：历史列表 + 预览 + 模板。
public struct ClipVaultToolView: View {
    @State private var entries: [ClipEntry] = []
    @State private var templates: [ClipTemplate] = []
    @State private var query = ""
    @State private var selectedID: String?
    @State private var statusMessage: String?
    @StateObject private var monitor = ClipVaultServices.monitor
    @State private var showingTemplateEditor = false
    @State private var newTemplateName = ""
    @State private var newTemplateContent = ""

    private let store = ClipVaultServices.store

    public init() {}

    public var body: some View {
        ToolContainer("剪贴板", subtitle: "ClipVault · 历史记录与模板") {
            VStack(spacing: 0) {
                toolbar

                if let message = statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }

                HSplitView {
                    listPane
                        .frame(minWidth: 300, idealWidth: 360)
                    detailPane
                        .frame(minWidth: 380)
                }
            }
        }
        .task { await reload() }
        .onReceive(monitor.$lastError.compactMap { $0 }) { error in
            statusMessage = "监控异常：\(error)"
        }
        .sheet(isPresented: $showingTemplateEditor) {
            templateEditorSheet
        }
    }

    private var templateEditorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建快捷模板").font(.headline)
            TextField("名称", text: $newTemplateName)
            TextField("内容（粘贴时展开）", text: $newTemplateContent, axis: .vertical)
                .lineLimit(3...6)
            HStack {
                Spacer()
                Button("取消") { showingTemplateEditor = false }
                Button("保存") {
                    Task {
                        try? await store.saveTemplate(name: newTemplateName, content: newTemplateContent)
                        newTemplateName = ""
                        newTemplateContent = ""
                        showingTemplateEditor = false
                        await reload()
                    }
                }
                .disabled(newTemplateName.isEmpty || newTemplateContent.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - 子视图

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索剪贴板历史", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await reload() } }
                .onChange(of: query) { _, _ in Task { await reload() } }
            Toggle(isOn: Binding(
                get: { !monitor.isRunning },
                set: { paused in setPaused(paused) })) {
                Label("暂停", systemImage: "pause.circle")
            }
            .toggleStyle(.button)
            .help(monitor.isRunning ? "暂停剪贴板监控" : "恢复剪贴板监控")

            Menu {
                Button("清空未保护的历史…") { clearAll(protected: false) }
                Button("清空全部（含固定/收藏）…", role: .destructive) { clearAll(protected: true) }
            } label: {
                Image(systemName: "trash")
            }

            Button {
                showingTemplateEditor = true
            } label: {
                Label("新建模板", systemImage: "square.and.pencil")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        Divider()
    }

    private var listPane: some View {
        List(entries, selection: $selectedID) { entry in
            ClipRow(entry: entry)
                .contextMenu {
                    Button(entry.pinned ? "取消固定" : "固定") {
                        Task {
                            try? await store.setPinned(id: entry.id, pinned: !entry.pinned)
                            await reload()
                        }
                    }
                    Button(entry.favorite ? "取消收藏" : "收藏") {
                        Task {
                            try? await store.setFavorite(id: entry.id, favorite: !entry.favorite)
                            await reload()
                        }
                    }
                    Button("复制内容") { Task { await copyEntry(entry, plainText: false) } }
                    Button("复制为纯文本") { Task { await copyEntry(entry, plainText: true) } }
                    Divider()
                    Button("删除", role: .destructive) {
                        Task {
                            try? await store.delete(id: entry.id)
                            await reload()
                        }
                    }
                }
        }
        .listStyle(.sidebar)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "暂无剪贴板历史" : "没有匹配结果",
                    systemImage: "doc.on.clipboard",
                    description: Text(query.isEmpty
                        ? "复制任意内容后将自动出现在这里。可在上方暂停监控。"
                        : "尝试其他关键词。"))
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let entry = entries.first(where: { $0.id == selectedID }) {
            ClipDetail(entry: entry) { action in
                Task { await perform(action, for: entry) }
            }
        } else {
            VStack(spacing: 16) {
                if !templates.isEmpty { templateList }
                Spacer()
                ContentUnavailableView("选择一条记录", systemImage: "hand.tap")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var templateList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快捷模板").font(.headline)
            ForEach(templates) { template in
                HStack {
                    Image(systemName: "text.quote")
                    VStack(alignment: .leading) {
                        Text(template.name).font(.callout)
                        Text(template.content).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(template.content, forType: .string)
                        statusMessage = "已复制模板「\(template.name)」"
                    }
                    Button(role: .destructive) {
                        Task {
                            try? await store.deleteTemplate(id: template.id)
                            await reload()
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    // MARK: - 动作

    enum DetailAction {
        case copy, copyPlain, togglePin, toggleFavorite, delete, pasteToFrontmost
    }

    private func perform(_ action: DetailAction, for entry: ClipEntry) async {
        switch action {
        case .copy: await copyEntry(entry, plainText: false)
        case .copyPlain: await copyEntry(entry, plainText: true)
        case .togglePin:
            try? await store.setPinned(id: entry.id, pinned: !entry.pinned)
            await reload()
        case .toggleFavorite:
            try? await store.setFavorite(id: entry.id, favorite: !entry.favorite)
            await reload()
        case .delete:
            try? await store.delete(id: entry.id)
            selectedID = nil
            await reload()
        case .pasteToFrontmost:
            await copyEntry(entry, plainText: true)
            await pasteToFrontmostApp()
        }
    }

    private func copyEntry(_ entry: ClipEntry, plainText: Bool) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch entry.kind {
        case .text, .url, .files:
            pasteboard.setString(entry.contentText ?? "", forType: .string)
        case .image:
            if let path = entry.filePath, let image = NSImage(contentsOfFile: path) {
                if plainText {
                    pasteboard.setString(path, forType: .string)
                } else {
                    pasteboard.writeObjects([image])
                }
            }
        }
        statusMessage = plainText ? "已复制为纯文本（⌘V 粘贴）" : "已复制（⌘V 粘贴）"
    }

    /// 向最前台应用模拟 ⌘V（需要辅助功能权限；未授权时明确提示，不静默失败）。
    private func pasteToFrontmostApp() async {
        let status = await Permissions.status(of: .accessibility)
        guard status == .granted else {
            _ = await Permissions.request(.accessibility)
            statusMessage = "模拟粘贴需要辅助功能权限；已复制内容，可直接 ⌘V。"
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9  // virtual key V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = [.maskCommand]
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = [.maskCommand]
        down?.post(tap: .cghidEventTap)
        usleep(30_000)
        up?.post(tap: .cghidEventTap)
    }

    private func setPaused(_ paused: Bool) {
        if paused {
            monitor.stop()
        } else {
            monitor.start()
        }
        ClipVaultServices.persistPauseState(paused)
    }

    private func clearAll(protected: Bool) {
        let alert = NSAlert()
        alert.messageText = protected ? "清空全部剪贴板历史？" : "清空未保护的剪贴板历史？"
        alert.informativeText = protected
            ? "包括固定与收藏的条目，删除后不可恢复（图片文件一并删除）。"
            : "固定与收藏的条目将保留。"
        alert.addButton(withTitle: protected ? "全部清空" : "清空")
        alert.addButton(withTitle: "取消")
        if protected { alert.alertStyle = .warning }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            try? await store.deleteAll(clearProtected: protected)
            selectedID = nil
            await reload()
        }
    }

    private func reload() async {
        do {
            if query.isEmpty {
                entries = try await store.entries()
            } else {
                entries = try await store.search(query)
            }
            templates = try await store.templates()
        } catch {
            statusMessage = "读取失败：\(String(describing: error))"
        }
    }
}

struct ClipRow: View {
    let entry: ClipEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.preview.isEmpty ? "（空）" : entry.preview)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.kind.displayName)
                    Text(Self.relativeDate(entry.createdAt))
                    if entry.pinned { Image(systemName: "pin.fill").font(.caption2) }
                    if entry.favorite { Image(systemName: "star.fill").font(.caption2) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    var icon: String {
        switch entry.kind {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        }
    }

    static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct ClipDetail: View {
    let entry: ClipEntry
    let onAction: (ClipVaultToolView.DetailAction) -> Void
    @State private var image: NSImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ClipRow(entry: entry)

                switch entry.kind {
                case .image:
                    Group {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 320)
                        } else {
                            Label("图片文件缺失", systemImage: "photo.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                case .text, .url, .files:
                    Text(entry.contentText ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                metadata

                HStack(spacing: 10) {
                    Button("复制") { onAction(.copy) }
                    Button("纯文本") { onAction(.copyPlain) }
                    Button(entry.pinned ? "取消固定" : "固定") { onAction(.togglePin) }
                    Button(entry.favorite ? "取消收藏" : "收藏") { onAction(.toggleFavorite) }
                    Button("删除", role: .destructive) { onAction(.delete) }
                }
            }
            .padding(16)
        }
        .task {
            image = nil
            if let path = entry.filePath {
                image = NSImage(contentsOfFile: path)
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("类型", value: entry.kind.displayName)
            LabeledContent("大小", value: entry.byteSize.formatted(.byteCount(style: .memory)))
            if let app = entry.sourceApp {
                LabeledContent("来源（近似）", value: app)
            }
            LabeledContent("时间", value: entry.createdAt.formatted(date: .abbreviated, time: .standard))
        }
        .font(.callout)
    }
}
