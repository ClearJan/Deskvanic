import AppKit
import DeskvanicCore
import DeskvanicUIShared
import PDFKit
import Quartz
import SwiftUI

/// Recall Vault 服务装配点。
@MainActor
public enum VaultServices {
    public static var store = makeDefaultStore()
    /// 共享数据库引用（备份等场景使用；由组合根注入）。
    public static var database = Database(url: AppEnvironment.databaseURL)

    public static func inject(store newStore: VaultStore, database newDatabase: Database) {
        store = newStore
        database = newDatabase
    }

    private static func makeDefaultStore() -> VaultStore {
        database = Database(url: AppEnvironment.databaseURL)
        return VaultStore(database: database, index: SearchIndex(database: database))
    }
}

/// Recall Vault 主界面。
public struct VaultToolView: View {
    @State private var items: [VaultItem] = []
    @State private var tagsByItem: [String: [String]] = [:]
    @State private var allTags: [String] = []
    @State private var query = ""
    @State private var kindFilter: VaultKind?
    @State private var tagFilter: String?
    @State private var favoriteOnly = false
    @State private var viewMode: ViewMode = .list
    @State private var selectedID: String?
    @State private var statusMessage: String?
    @State private var showAddText = false
    @State private var showAddURL = false
    @State private var showBackup = false

    public enum ViewMode: String, CaseIterable {
        case list = "列表"
        case grid = "网格"
    }

    private let store = VaultServices.store

    public init() {}

    public var body: some View {
        ToolContainer("资料检索中心", subtitle: "Recall Vault · 收藏 · 标签 · 全文检索") {
            VStack(spacing: 0) {
                toolbar
                filterBar
                if let message = statusMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HSplitView {
                    contentPane.frame(minWidth: 320, idealWidth: 400)
                    detailPane.frame(minWidth: 420)
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showAddText) { addTextSheet }
        .sheet(isPresented: $showAddURL) { addURLSheet }
        .sheet(isPresented: $showBackup) { backupSheet }
    }

    // MARK: - 工具栏

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("全文搜索标题、内容与 OCR 文本", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await reload() } }
                .onChange(of: query) { _, _ in Task { await reload() } }
            Picker("视图", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            Menu {
                Button("添加文本…") { showAddText = true }
                Button("保存链接…") { showAddURL = true }
                Button("导入文件（复制进库）…") { importFiles(copyMode: true) }
                Button("引用文件（保留原位置）…") { importFiles(copyMode: false) }
                Divider()
                Button("备份资料库…") { showBackup = true }
            } label: {
                Label("添加", systemImage: "plus")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        Divider()
    }

    @ViewBuilder
    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("类型", selection: Binding(
                get: { kindFilter },
                set: { kindFilter = $0; Task { await reload() } })) {
                Text("全部类型").tag(VaultKind?.none)
                ForEach(VaultKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(VaultKind?.some(kind))
                }
            }
            .frame(width: 130)

            if !allTags.isEmpty {
                Menu {
                    Button("清除标签筛选") { tagFilter = nil; Task { await reload() } }
                    ForEach(allTags, id: \.self) { tag in
                        Button(tag) { tagFilter = tag; Task { await reload() } }
                    }
                } label: {
                    Label(tagFilter ?? "标签", systemImage: "tag")
                }
            }

            Toggle(isOn: Binding(
                get: { favoriteOnly },
                set: { favoriteOnly = $0; Task { await reload() } })) {
                Label("收藏", systemImage: "star")
            }
            .toggleStyle(.button)

            Spacer()
            Text("\(items.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        Divider()
    }

    // MARK: - 内容

    private var contentPane: some View {
        Group {
            if viewMode == .list {
                List(items, selection: $selectedID) { item in
                    VaultRow(item: item, tags: tagsByItem[item.id] ?? [])
                        .contextMenu { contextActions(for: item) }
                }
                .listStyle(.sidebar)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                        ForEach(items) { item in
                            VaultCard(item: item)
                                .onTapGesture { selectedID = item.id }
                                .contextMenu { contextActions(for: item) }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "资料库为空" : "没有匹配结果",
                    systemImage: "archivebox",
                    description: Text(query.isEmpty
                        ? "用「添加」菜单保存文本、链接、图片、PDF 或文件引用。"
                        : "调整关键词或清除筛选。"))
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let item = items.first(where: { $0.id == selectedID }) {
            VaultDetail(item: item, tags: tagsByItem[item.id] ?? []) { action in
                Task { await perform(action, for: item) }
            }
        } else {
            ContentUnavailableView("选择一条资料", systemImage: "doc.text.magnifyingglass")
        }
    }

    @ViewBuilder
    private func contextActions(for item: VaultItem) -> some View {
        Button(item.favorite ? "取消收藏" : "收藏") {
            Task { await perform(.toggleFavorite, for: item) }
        }
        Button("复制内容") { Task { await perform(.copy, for: item) } }
        Button("在访达中显示") { Task { await perform(.reveal, for: item) } }
        Button("运行 OCR") { Task { await perform(.ocr, for: item) } }
        Divider()
        Button("删除", role: .destructive) { Task { await perform(.delete, for: item) } }
    }

    // MARK: - 添加面板

    private var addTextSheet: some View {
        AddTextSheet { title, content, tags in
            let item = VaultItem(kind: .text, title: title, contentText: content, tags: tags)
            try? await store.add(item)
            showAddText = false
            await reload()
        }
    }

    private var addURLSheet: some View {
        AddURLSheet { urlString, tags in
            guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else {
                statusMessage = "仅支持 http/https 链接"
                return
            }
            let item = VaultItem(
                kind: .url, title: url.host ?? urlString,
                contentText: url.absoluteString, tags: tags)
            try? await store.add(item)
            showAddURL = false
            await reload()
        }
    }

    private var backupSheet: some View {
        BackupSheet { await performBackup() }
    }

    // MARK: - 动作

    enum DetailAction {
        case toggleFavorite, copy, reveal, ocr, delete, openOriginal
    }

    private func perform(_ action: DetailAction, for item: VaultItem) async {
        switch action {
        case .toggleFavorite:
            try? await store.setFavorite(id: item.id, favorite: !item.favorite)
            await reload()
        case .copy:
            NSPasteboard.general.clearContents()
            switch item.kind {
            case .text, .url:
                NSPasteboard.general.setString(item.contentText ?? item.title, forType: .string)
            default:
                if let path = item.effectiveFilePath, let image = NSImage(contentsOfFile: path) {
                    NSPasteboard.general.writeObjects([image])
                } else {
                    NSPasteboard.general.setString(item.title, forType: .string)
                }
            }
            statusMessage = "已复制"
        case .reveal:
            if let path = item.effectiveFilePath {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        case .openOriginal:
            if let path = item.effectiveFilePath {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else if item.kind == .url, let url = URL(string: item.contentText ?? "") {
                NSWorkspace.shared.open(url)
            }
        case .ocr:
            await runOCR(for: item)
        case .delete:
            try? await store.delete(id: item.id)
            selectedID = nil
            await reload()
        }
    }

    private func importFiles(copyMode: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = copyMode ? "文件将复制进资料库（原文件不动）" : "仅记录文件当前位置"
        panel.begin { response in
            guard response == .OK else { return }
            Task { await importFiles(urls: panel.urls, copyMode: copyMode) }
        }
    }

    private func importFiles(urls: [URL], copyMode: Bool) async {
        var imported = 0
        for url in urls {
            let kind: VaultKind
            switch url.pathExtension.lowercased() {
            case "png", "jpg", "jpeg", "heic", "gif", "tiff", "webp": kind = .image
            case "pdf": kind = .pdf
            default: kind = .file
            }
            var storagePath: String?
            if copyMode {
                do {
                    let dest = try copyIntoVaultStorage(url)
                    storagePath = dest.path
                } catch {
                    statusMessage = "复制失败：\(url.lastPathComponent) — \(String(describing: error))"
                    continue
                }
            }
            let item = VaultItem(
                kind: kind,
                title: url.deletingPathExtension().lastPathComponent,
                storagePath: storagePath,
                referencePath: copyMode ? nil : url.path,
                storageMode: copyMode ? .copied : .referenced)
            do {
                try await store.add(item)
                imported += 1
                if kind == .image || kind == .pdf {
                    await runOCR(for: item)
                }
            } catch {
                statusMessage = "导入失败：\(String(describing: error))"
            }
        }
        statusMessage = "已导入 \(imported) 条（\(copyMode ? "复制" : "引用")模式）"
        await reload()
    }

    /// 把文件复制进 VaultStorage（按条目子目录隔离）。
    private func copyIntoVaultStorage(_ source: URL) throws -> URL {
        let itemID = UUID().uuidString
        let dir = AppEnvironment.vaultStorageDirectory.appendingPathComponent(itemID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = FileSafety.uniqueDestination(in: dir, preferredName: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: dest)
        try FileSafety.validateOutput(at: dest,
                                      expectedMinBytes: Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
        return dest
    }

    private func runOCR(for item: VaultItem) async {
        guard let path = item.effectiveFilePath else { return }
        guard let nsImage = NSImage(contentsOfFile: path),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // PDF：取第一页
            if item.kind == .pdf, let pdfDoc = PDFDocument(url: URL(fileURLWithPath: path)),
               let page = pdfDoc.page(at: 0),
               let cg = page.thumbnail(of: page.bounds(for: .mediaBox).size, for: .mediaBox)
                   .cgImage(forProposedRect: nil, context: nil, hints: nil) {
                await performOCR(cg, item: item)
            }
            return
        }
        await performOCR(cg, item: item)
    }

    private func performOCR(_ cg: CGImage, item: VaultItem) async {
        guard let current = try? await store.item(id: item.id) else { return }
        if let result = try? await OCREngine.recognizeText(in: cg) {
            var updated = current
            updated.ocrText = result.fullText
            try? await store.update(updated)
            statusMessage = result.fullText.isEmpty ? "未识别到文本" : "OCR 完成，已更新检索索引"
            await reload()
        }
    }

    private func performBackup() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择备份输出目录（将写入 Deskvanic-Vault-Backup 文件夹）"
        panel.begin { response in
            guard response == .OK, let dir = panel.url else { return }
            Task {
                do {
                    let stamp = Int(Date().timeIntervalSince1970)
                    let backupDir = dir.appendingPathComponent("Deskvanic-Vault-Backup-\(stamp)", isDirectory: true)
                    try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
                    // 1. 数据库备份
                    try await VaultServices.database.backup(to: backupDir.appendingPathComponent("Deskvanic.sqlite"))
                    // 2. 库内文件
                    let fm = FileManager.default
                    let storage = AppEnvironment.vaultStorageDirectory
                    if fm.fileExists(atPath: storage.path) {
                        try? fm.copyItem(at: storage, to: backupDir.appendingPathComponent("VaultStorage"))
                    }
                    statusMessage = "备份完成：\(backupDir.lastPathComponent)"
                } catch {
                    statusMessage = "备份失败：\(String(describing: error))"
                }
            }
        }
    }

    private func reload() async {
        do {
            let filter = VaultStore.Filter(
                query: query, kind: kindFilter, tag: tagFilter, favoriteOnly: favoriteOnly)
            items = try await store.items(filter: filter)
            tagsByItem = try await store.tagsByItem()
            allTags = try await store.allTags()
        } catch {
            statusMessage = "读取失败：\(String(describing: error))"
        }
    }
}

// MARK: - 子视图

struct VaultRow: View {
    let item: VaultItem
    let tags: [String]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1)
                    if item.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                    if case .missing = item.fileStatus {
                        Label("文件缺失", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 6) {
                    Text(item.kind.displayName)
                    if item.storageMode == .referenced {
                        Text("引用").font(.caption2)
                    }
                    ForEach(tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)").font(.caption2).foregroundStyle(.teal)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.createdAt.formatted(date: .numeric, time: .omitted))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    var icon: String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .file: return "doc"
        }
    }
}

struct VaultCard: View {
    let item: VaultItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
                .frame(height: 84)
                .frame(maxWidth: .infinity)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            Text(item.title)
                .font(.callout)
                .lineLimit(1)
            HStack {
                Text(item.kind.displayName)
                if case .missing = item.fileStatus {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Spacer()
                if item.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.kind {
        case .image:
            if let path = item.effectiveFilePath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).clipped()
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        case .pdf:
            Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(.tertiary)
        case .url:
            Image(systemName: "link").font(.largeTitle).foregroundStyle(.tertiary)
        case .text:
            Text(item.contentText ?? "")
                .font(.caption2)
                .lineLimit(5)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .file:
            Image(systemName: "doc").font(.largeTitle).foregroundStyle(.tertiary)
        }
    }
}

struct VaultDetail: View {
    let item: VaultItem
    let tags: [String]
    let onAction: (VaultToolView.DetailAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(item.title).font(.title3.bold())
                    Spacer()
                    Button(item.favorite ? "★" : "☆") { onAction(.toggleFavorite) }
                }

                preview

                HStack(spacing: 10) {
                    Button("打开") { onAction(.openOriginal) }
                    Button("复制") { onAction(.copy) }
                    if item.effectiveFilePath != nil {
                        Button("在访达中显示") { onAction(.reveal) }
                        Button("OCR") { onAction(.ocr) }
                    }
                    Spacer()
                    Button("删除", role: .destructive) { onAction(.delete) }
                }

                if case .missing = item.fileStatus {
                    Label(
                        "原文件已移动或删除，当前记录的路径已失效：\(item.effectiveFilePath ?? "")",
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if item.storageMode == .referenced {
                    Text("引用模式：文件保留在原位置，Deskvanic 不持有副本。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !tags.isEmpty {
                    HStack {
                        ForEach(tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quinary, in: Capsule())
                        }
                    }
                }

                if let ocr = item.ocrText, !ocr.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("识别文本").font(.headline)
                        Text(ocr)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            Text(item.contentText ?? "")
                .font(.body)
                .textSelection(.enabled)
        case .url:
            if let urlString = item.contentText, let url = URL(string: urlString) {
                Link(urlString, destination: url)
                    .font(.callout)
            }
        case .image:
            if let path = item.effectiveFilePath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 320)
                    .frame(maxWidth: .infinity)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Label("图片不可用", systemImage: "photo.badge.exclamationmark")
            }
        case .pdf:
            if let path = item.effectiveFilePath {
                PDFPreview(url: URL(fileURLWithPath: path))
                    .frame(height: 360)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Label("PDF 不可用", systemImage: "doc.badge.exclamationmark")
            }
        case .file:
            if let path = item.effectiveFilePath {
                Label(path, systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}

struct AddTextSheet: View {
    let onSave: (String, String, [String]) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var tagsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保存文本").font(.headline)
            TextField("标题", text: $title)
            TextField("内容", text: $content, axis: .vertical)
                .lineLimit(4...10)
            TextField("标签（逗号分隔）", text: $tagsText)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    Task {
                        await onSave(title.isEmpty ? String(content.prefix(30)) : title, content, tags)
                        dismiss()
                    }
                }
                .disabled(content.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct AddURLSheet: View {
    let onSave: (String, [String]) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var tagsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保存链接").font(.headline)
            TextField("https://…", text: $urlString)
            TextField("标签（逗号分隔）", text: $tagsText)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    Task {
                        await onSave(urlString, tags)
                        dismiss()
                    }
                }
                .disabled(urlString.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct BackupSheet: View {
    let onBackup: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("备份资料库").font(.headline)
            Text("备份包含：完整数据库（全部模块数据）与库内文件副本。引用模式的原始文件不在备份范围内。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("选择目录并备份") {
                    Task {
                        await onBackup()
                        dismiss()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
