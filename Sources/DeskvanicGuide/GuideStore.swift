import AppKit
import DeskvanicCapture
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// GuideCraft 服务装配点。
@MainActor
public enum GuideServices {
    public static var store = GuideStore(database: Database(url: AppEnvironment.databaseURL))
    public static let capturesDirectory = AppEnvironment.capturesDirectory.appendingPathComponent("Guides", isDirectory: true)

    public static func inject(store newStore: GuideStore) {
        store = newStore
    }
}

/// 教程持久化（数据库 v10）。
public struct GuideRecord: Identifiable, Codable, Sendable {
    public let id: String
    public var document: GuideDocument
    public let updatedAt: Date
}

public actor GuideStore {
    private let db: Database

    public init(database: Database) {
        self.db = database
    }

    public func save(_ record: GuideRecord) async throws {
        let data = try JSONEncoder().encode(record)
        _ = try await db.runUpdate(
            "INSERT OR REPLACE INTO guides(id, title, data, updated_at) VALUES(?,?,?,?)",
            [.text(record.id), .text(record.document.title), .blob(data), .text(DateCodec.encode(record.updatedAt))])
    }

    public func delete(id: String) async throws {
        _ = try await db.runUpdate("DELETE FROM guides WHERE id = ?", [.text(id)])
        // 清理该教程的截图目录，避免孤儿文件（审计 #17）
        let guideDir = AppEnvironment.capturesDirectory
            .appendingPathComponent("Guides", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: guideDir)
    }

    public func loadAll() async throws -> [GuideRecord] {
        let rows = try await db.run("SELECT id, data FROM guides ORDER BY updated_at DESC")
        return rows.compactMap { row in
            guard let id = row["id"]?.stringValue,
                  let data = row["data"]?.blobValue else { return nil }
            return try? JSONDecoder().decode(GuideRecord.self, from: data)
        }
    }
}

/// GuideCraft 数据库迁移（版本 10）。
public enum GuideSchema {
    public static let migration = DBMigration(version: 10, name: "guide-craft", statements: [
        """
        CREATE TABLE guides(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            data BLOB NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    ])
}

/// GuideCraft 主界面。
public struct GuideCraftView: View {
    @State private var guides: [GuideRecord] = []
    @State private var current: GuideDocument?
    @State private var statusMessage: String?
    @State private var findings: [GuideEngine.PrivacyFinding] = []
    @State private var capturingStepTitle = ""
    @State private var showRegionSelector = false

    public init() {}

    public var body: some View {
        ToolContainer("操作教程生成", subtitle: "GuideCraft · 截图步骤 → 说明 → 导出") {
            HSplitView {
                guideList.frame(minWidth: 220, idealWidth: 250)
                editorPane.frame(minWidth: 560)
            }
        }
        .task { await reload() }
    }

    private var guideList: some View {
        List(guides, selection: Binding(
            get: { current?.id },
            set: { id in
                current = guides.first { $0.id == id }?.document
                findings = []
            })) { record in
            VStack(alignment: .leading) {
                Text(record.document.title).lineLimit(1)
                Text("\(record.document.steps.count) 步").font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack {
                Button("新建教程") {
                    current = GuideDocument(title: "新教程")
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .overlay {
            if guides.isEmpty {
                ContentUnavailableView("暂无教程", systemImage: "doc.text.below.ecg")
            }
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if $current != nil, let document = current {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        TextField("教程标题", text: Binding(
                            get: { document.title },
                            set: { current?.title = $0 }))
                            .textFieldStyle(.roundedBorder)
                        Button("保存") { Task { await save() } }
                        Menu {
                            Button("导出 Markdown…") { Task { await export(.markdown) } }
                            Button("导出独立 HTML…") { Task { await export(.html) } }
                            Button("导出 PDF…") { Task { await export(.pdf) } }
                        } label: {
                            Label("导出", systemImage: "square.and.arrow.up")
                        }
                    }

                    captureSection

                    privacySection

                    stepsSection

                    if let message = statusMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("选择或新建教程", systemImage: "doc.text.below.ecg")
        }
    }

    private var captureSection: some View {
        GroupBox("捕获步骤") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("步骤标题（可后改）", text: $capturingStepTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Button("全屏截图为步骤") { Task { await captureStep(region: nil) } }
                    Button("区域截图为步骤…") {
                        guard CaptureEngine.hasScreenPermission() else {
                            CaptureEngine.requestScreenPermission()
                            statusMessage = "需要屏幕录制权限（系统设置 → 屏幕录制）"
                            return
                        }
                        RegionSelector.shared.begin { rect in
                            guard let rect else { return }
                            Task { await captureStep(region: rect) }
                        }
                    }
                }
                Text("每个步骤自动叠加序号标注；截图保存在本机。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var privacySection: some View {
        GroupBox("敏感信息检查（OCR 启发式，需人工复核）") {
            VStack(alignment: .leading, spacing: 6) {
                Button("扫描全部步骤截图") {
                    Task {
                        guard let current else { return }
                        findings = await GuideEngine.privacyScan(document: current)
                        statusMessage = findings.isEmpty ? "未发现可疑关键词（仍建议人工浏览截图）"
                            : "发现 \(findings.count) 处可疑内容，请人工复核"
                    }
                }
                .disabled(current?.steps.isEmpty != false)
                ForEach(findings) { finding in
                    HStack {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                        Text("步骤 \(finding.stepIndex)：关键词「\(finding.keyword)」")
                            .font(.caption)
                        Text(finding.snippet).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var stepsSection: some View {
        GroupBox("步骤（\(current?.steps.count ?? 0)）") {
            VStack(alignment: .leading, spacing: 10) {
                if let document = current, !document.steps.isEmpty {
                    ForEach(Array(document.steps.enumerated()), id: \.element.id) { index, step in
                        stepRow(index: index, step: step)
                    }
                } else {
                    Text("尚无步骤").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func stepRow(index: Int, step: GuideStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let image = NSImage(contentsOfFile: step.imagePath) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 90, height: 56)
                    .clipped()
                    .cornerRadius(4)
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .frame(width: 90, height: 56)
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("标题", text: Binding(
                    get: { step.title },
                    set: { current?.steps[index].title = $0 }))
                    .textFieldStyle(.roundedBorder)
                TextField("操作说明", text: Binding(
                    get: { step.description },
                    set: { current?.steps[index].description = $0 }))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("上移") {
                        guard index > 0 else { return }
                        current?.steps.swapAt(index, index - 1)
                    }
                    Button("下移") {
                        guard let count = current?.steps.count, index < count - 1 else { return }
                        current?.steps.swapAt(index, index + 1)
                    }
                    Button("删除", role: .destructive) {
                        current?.steps.remove(at: index)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer()
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 动作

    private func reload() async {
        guides = (try? await GuideServices.store.loadAll()) ?? []
        if current == nil {
            current = guides.first?.document
        }
    }

    private func captureStep(region: CGRect?) async {
        guard let document = current else { return }
        let storageDir = GuideServices.capturesDirectory.appendingPathComponent(document.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        do {
            let step = try GuideEngine.captureStep(
                number: document.steps.count + 1,
                title: capturingStepTitle.isEmpty ? "步骤 \(document.steps.count + 1)" : capturingStepTitle,
                region: region, storageDirectory: storageDir)
            current?.steps.append(step)
            capturingStepTitle = ""
            statusMessage = "已捕获步骤 \(document.steps.count)"
        } catch {
            statusMessage = "捕获失败：\(String(describing: error))"
        }
    }

    private func save() async {
        guard let document = current else { return }
        let record = GuideRecord(id: document.id, document: document, updatedAt: Date())
        try? await GuideServices.store.save(record)
        await reload()
        statusMessage = "已保存"
    }

    private enum ExportFormat {
        case markdown, html, pdf

        var extensionName: String {
            switch self {
            case .markdown: return "md"
            case .html: return "html"
            case .pdf: return "pdf"
            }
        }
    }

    private func export(_ format: ExportFormat) async {
        guard let document = current, !document.steps.isEmpty else {
            statusMessage = "教程没有步骤，无法导出"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .markdown ? .plainText : (format == .html ? .html : .pdf)]
        panel.nameFieldStringValue = "\(document.title).\(format.extensionName)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let dir = url.deletingLastPathComponent()
            // base64/PDF 绘制是重活，放后台队列避免主线程卡顿（审计 #7）
            Task {
                await TaskQueue.shared.enqueue(title: "导出教程：\(document.title)") { _ in
                    let output: URL
                    switch format {
                    case .markdown: output = try GuideEngine.exportMarkdown(document: document, to: dir)
                    case .html: output = try GuideEngine.exportHTML(document: document, to: dir)
                    case .pdf: output = try GuideEngine.exportPDF(document: document, to: dir)
                    }
                    if output.lastPathComponent != url.lastPathComponent {
                        try? FileManager.default.moveItem(at: output, to: url)
                    }
                    await MainActor.run {
                        statusMessage = "导出完成：\(url.lastPathComponent)"
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
    }
}
