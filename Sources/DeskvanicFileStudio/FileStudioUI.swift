import AppKit
import DeskvanicCore
import DeskvanicUIShared
import PDFKit
import QuickLookThumbnailing
import SwiftUI

/// File Studio 服务装配点。
@MainActor
public enum FileStudioServices {
    public static var database = Database(url: AppEnvironment.databaseURL)

    public static func inject(database: Database) {
        self.database = database
    }
}

/// 暂存文件条目。
public struct StagedFile: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public var fileSize: Int64

    public init(url: URL) {
        self.id = UUID()
        self.url = url
        self.fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    public var kind: StagedKind {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "tiff", "webp": return .image
        case "pdf": return .pdf
        case "zip": return .zip
        default: return .other
        }
    }
}

public enum StagedKind: Sendable, Hashable {
    case image, pdf, zip, other
}

/// 处理模板（重命名预设等），持久化到 kv_store。
public struct RenameTemplate: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var mode: BatchRenameEngine.Mode
    public var patternBase: String
    public var find: String
    public var replacement: String
    public var prefix: String
    public var suffix: String
    public var padding: Int

    public init(
        id: String = UUID().uuidString, name: String, mode: BatchRenameEngine.Mode,
        patternBase: String = "文件", find: String = "", replacement: String = "",
        prefix: String = "", suffix: String = "", padding: Int = 2
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.patternBase = patternBase
        self.find = find
        self.replacement = replacement
        self.prefix = prefix
        self.suffix = suffix
        self.padding = padding
    }
}

public actor TemplateStore {
    private let db: Database
    private let key = "fileStudio.templates"

    public init(database: Database) {
        self.db = database
    }

    public func load() async -> [RenameTemplate] {
        guard let rows = try? await db.run("SELECT value FROM kv_store WHERE key = ?", [.text(key)]),
              let json = rows.first?["value"]?.stringValue,
              let data = json.data(using: .utf8),
              let templates = try? JSONDecoder().decode([RenameTemplate].self, from: data) else {
            return []
        }
        return templates
    }

    public func save(_ templates: [RenameTemplate]) async {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        _ = try? await db.runUpdate(
            "INSERT INTO kv_store(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(String(data: data, encoding: .utf8) ?? "[]")])
    }
}

/// 单文件大小上限（防误处理超大文件）：500 MB，可配置放宽。
public enum FileStudioLimits {
    public static let maxSingleFileSize: Int64 = 500 * 1024 * 1024

    public static func validate(_ file: StagedFile) throws {
        guard FileManager.default.fileExists(atPath: file.url.path) else {
            throw DeskvanicError(.fileNotFound, "文件不存在：\(file.url.lastPathComponent)")
        }
        guard file.fileSize <= maxSingleFileSize else {
            throw DeskvanicError(
                .invalidInput,
                "文件超过大小限制（\(file.fileSize.formatted(.byteCount(style: .memory))) > \(maxSingleFileSize.formatted(.byteCount(style: .memory))))",
                recovery: "请拆分文件或压缩后再处理。")
        }
    }
}

/// File Studio 主界面。
public struct FileStudioView: View {
    @State private var staged: [StagedFile] = []
    @State private var outputDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    @State private var statusMessage: String?
    @State private var activeJobs: [TaskQueue.JobHistoryItem] = []

    // PDF 操作参数
    @State private var rotateDegrees = 90
    @State private var extractPagesText = "1-3"
    @State private var optimizeQuality = 0.6
    @State private var optimizeScale = 1.0

    // 图片处理参数
    @State private var imageFormat: ImageEngine.Format = .jpeg
    @State private var imageQuality = 0.85
    @State private var resizeMaxPixel = 1024
    @State private var compressTargetMB = 0.5
    @State private var lastCompressReport: String?

    // ZIP 参数
    @State private var zipKeepRelativePaths = false
    @State private var zipExtractDir: URL?

    // 重命名
    @State private var renameMode: BatchRenameEngine.Mode = .pattern
    @State private var renamePatternBase = "文件"
    @State private var renameFind = ""
    @State private var renameReplacement = ""
    @State private var renamePrefix = ""
    @State private var renameSuffix = ""
    @State private var renamePadding = 2
    @State private var renamePlan: BatchRenameEngine.Plan?
    @State private var templates: [RenameTemplate] = []
    @State private var newTemplateName = ""

    private let templateStore = TemplateStore(database: Database(url: AppEnvironment.databaseURL))

    public init() {}

    public var body: some View {
        ToolContainer("文件处理中心", subtitle: "File Studio · 暂存 → 处理 → 校验输出") {
            VStack(spacing: 0) {
                HStack {
                    Text("输出目录：\(outputDirectory.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("更改…") { chooseOutputDirectory() }
                    Spacer()
                    if let message = statusMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                HSplitView {
                    stagingPane.frame(minWidth: 340, idealWidth: 400)
                    operationsPane.frame(minWidth: 420)
                }
            }
        }
        .task {
            templates = await templateStore.load()
        }
    }

    // MARK: - 暂存区

    private var stagingPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("暂存（\(staged.count)）").font(.headline)
                Spacer()
                Button("添加…") { addFiles() }
                Button("清空", role: .destructive) { staged.removeAll() }
                    .disabled(staged.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            dropZone
                .overlay {
                    if !staged.isEmpty {
                        stagedList
                    }
                }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("拖拽文件到此处，或点「添加」")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private var stagedList: some View {
        List {
            ForEach(staged) { file in
                StagedRow(file: file) {
                    staged.removeAll { $0.id == file.id }
                }
            }
            .onMove { indices, newOffset in
                staged.move(fromOffsets: indices, toOffset: newOffset)
            }
        }
        .listStyle(.plain)
        .background(.background.secondary)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = try? URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsurl = item as? URL {
                    url = nsurl
                } else if let nsurl = item as? NSURL {
                    url = nsurl as URL
                }
                guard let url else { return }
                Task { @MainActor in
                    staged.append(StagedFile(url: url))
                }
            }
        }
        return !fileProviders.isEmpty
    }

    // MARK: - 操作面板

    private var operationsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pdfSection
                imageSection
                zipSection
                renameSection
            }
            .padding(16)
        }
    }

    private var pdfSection: some View {
        GroupBox("PDF 处理（对暂存的 PDF 按顺序应用）") {
            VStack(alignment: .leading, spacing: 10) {
                let pdfs = staged.filter { $0.kind == .pdf }
                HStack(spacing: 10) {
                    Button("合并（≥2 个）") { runPDFMerge(pdfs) }
                        .disabled(pdfs.count < 2)
                    Button("逐页拆分（首个）") { runPDFSplit(pdfs) }
                        .disabled(pdfs.isEmpty)
                }
                HStack(spacing: 10) {
                    Picker("旋转角度", selection: $rotateDegrees) {
                        Text("90°").tag(90)
                        Text("180°").tag(180)
                        Text("270°").tag(270)
                    }
                    .frame(width: 110)
                    Button("全部旋转（首个）") { runPDFRotate(pdfs) }
                        .disabled(pdfs.isEmpty)
                }
                HStack(spacing: 10) {
                    TextField("提取页码（如 1,3-5）", text: $extractPagesText)
                        .textFieldStyle(.roundedBorder)
                    Button("提取页面") { runPDFExtract(pdfs) }
                        .disabled(pdfs.isEmpty)
                }
                HStack(spacing: 10) {
                    Text("优化：质量 \(Int(optimizeQuality * 100))%，缩放 \(Int(optimizeScale * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $optimizeQuality, in: 0.3...0.95)
                    Slider(value: $optimizeScale, in: 0.5...1.0)
                    Button("体积优化（首个）") { runPDFOptimize(pdfs) }
                        .disabled(pdfs.isEmpty)
                }
                Text("优化说明：页面转为位图后文本不可选中、注释与书签丢失；不保证达到特定体积，结果会如实报告。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if pdfs.isEmpty {
                    Text("暂存区没有 PDF 文件")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var imageSection: some View {
        GroupBox("图片处理（对暂存的图片应用；原文件不动，输出到指定目录）") {
            VStack(alignment: .leading, spacing: 10) {
                let images = staged.filter { $0.kind == .image }
                if images.isEmpty {
                    Text("暂存区没有图片文件")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 10) {
                    Picker("目标格式", selection: $imageFormat) {
                        ForEach(ImageEngine.Format.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .frame(width: 120)
                    if imageFormat == .jpeg || imageFormat == .heic {
                        Text("质量 \(Int(imageQuality * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: $imageQuality, in: 0.3...0.95)
                            .frame(width: 120)
                    }
                    Button("逐张转换") { runImageConvert(images) }
                        .disabled(images.isEmpty)
                }
                HStack(spacing: 10) {
                    Stepper("最长边 \(resizeMaxPixel) px", value: $resizeMaxPixel, in: 16...8192, step: 16)
                        .frame(width: 220)
                    Button("逐张缩放") { runImageResize(images) }
                        .disabled(images.isEmpty)
                }
                HStack(spacing: 10) {
                    Stepper("目标 ≤ \(compressTargetMB, specifier: "%.1f") MB", value: $compressTargetMB, in: 0.05...20)
                        .frame(width: 200)
                    Button("逐张压缩") { runImageCompress(images) }
                        .disabled(images.isEmpty)
                    Button("清除位置等隐私元数据") { runStripMetadata(images) }
                        .disabled(images.isEmpty)
                }
                if let lastCompressReport {
                    Text(lastCompressReport)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var zipSection: some View {
        GroupBox("ZIP 打包与解压") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("压缩时保留相对路径结构", isOn: $zipKeepRelativePaths)
                HStack(spacing: 10) {
                    Button("打包暂存文件为 ZIP…") { runZipCreate() }
                        .disabled(staged.isEmpty)
                    Button("解压暂存的 ZIP…") { runZipExtract() }
                        .disabled(!staged.contains { $0.kind == .zip })
                }
                Text("解压内置防护：路径穿越/绝对路径/符号链接条目一律拒绝并记录；CRC 校验失败即中止；单文件 2GB、总量 10GB 上限。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - 图片操作

    private func runImageConvert(_ images: [StagedFile]) {
        guard guardLimits(images) else { return }
        let format = imageFormat
        let quality = imageQuality
        let outputDir = outputDirectory
        Task {
            await TaskQueue.shared.enqueue(title: "图片转换 ×\(images.count) → \(format.displayName)") { context in
                for (index, image) in images.enumerated() {
                    let report = try ImageEngine.convert(
                        source: image.url, to: format, destinationDirectory: outputDir, quality: quality)
                    try FileSafety.validateOutput(at: report.outputURL)
                    context.progress(Double(index + 1) / Double(images.count))
                }
                await MainActor.run { statusMessage = "转换完成：\(images.count) 张 → \(format.displayName)" }
            }
        }
    }

    private func runImageResize(_ images: [StagedFile]) {
        guard guardLimits(images) else { return }
        let maxPixel = resizeMaxPixel
        let outputDir = outputDirectory
        Task {
            await TaskQueue.shared.enqueue(title: "图片缩放 ×\(images.count) → \(maxPixel)px") { context in
                for (index, image) in images.enumerated() {
                    let output = try ImageEngine.resize(
                        source: image.url, maxPixel: maxPixel, destinationDirectory: outputDir)
                    try FileSafety.validateOutput(at: output)
                    context.progress(Double(index + 1) / Double(images.count))
                }
                await MainActor.run { statusMessage = "缩放完成：\(images.count) 张（≤\(maxPixel)px）" }
            }
        }
    }

    private func runImageCompress(_ images: [StagedFile]) {
        guard guardLimits(images) else { return }
        let target = Int64(compressTargetMB * 1024 * 1024)
        let outputDir = outputDirectory
        let targetLabel = String(format: "%.1f", compressTargetMB)
        Task {
            await TaskQueue.shared.enqueue(title: "图片压缩 ×\(images.count) → ≤\(targetLabel)MB") { context in
                var reached = 0
                for (index, image) in images.enumerated() {
                    let report = try ImageEngine.compress(
                        source: image.url, targetBytes: target, destinationDirectory: outputDir)
                    if report.reachedTarget { reached += 1 }
                    context.progress(Double(index + 1) / Double(images.count))
                }
                await MainActor.run {
                    lastCompressReport = "达到目标：\(reached)/\(images.count) 张（PNG 为无损格式时可能无法达标，已如实标注）"
                    statusMessage = lastCompressReport!
                }
            }
        }
    }

    private func runStripMetadata(_ images: [StagedFile]) {
        guard guardLimits(images) else { return }
        let outputDir = outputDirectory
        Task {
            await TaskQueue.shared.enqueue(title: "剥离隐私元数据 ×\(images.count)") { context in
                for (index, image) in images.enumerated() {
                    let output = try ImageEngine.stripMetadata(
                        source: image.url, destinationDirectory: outputDir)
                    try FileSafety.validateOutput(at: output)
                    context.progress(Double(index + 1) / Double(images.count))
                }
                await MainActor.run { statusMessage = "元数据剥离完成（输出已复核无 GPS/IPTC）" }
            }
        }
    }

    // MARK: - ZIP 操作

    private func runZipCreate() {
        let files = staged.map(\.url)
        let keepRelative = zipKeepRelativePaths
        let outputDir = outputDirectory
        Task {
            await TaskQueue.shared.enqueue(title: "打包 ZIP（\(files.count) 个）") { context in
                context.progress(0.1)
                let archiveName = "archive-\(Int(Date().timeIntervalSince1970)).zip"
                let destination = FileSafety.uniqueDestination(in: outputDir, preferredName: archiveName)
                try ZIPArchive.createArchive(
                    at: destination, adding: files, options: .init(keepRelativePaths: keepRelative))
                try FileSafety.validateOutput(at: destination)
                await MainActor.run { statusMessage = "打包完成：\(destination.lastPathComponent)" }
            }
        }
    }

    private func runZipExtract() {
        guard let zip = staged.first(where: { $0.kind == .zip }) else { return }
        let archiveURL = zip.url
        Task {
            await TaskQueue.shared.enqueue(title: "解压 ZIP：\(zip.url.lastPathComponent)") { context in
                context.progress(0.1)
                let extractDir = FileSafety.uniqueDestination(
                    in: archiveURL.deletingLastPathComponent(),
                    preferredName: ((archiveURL.lastPathComponent as NSString).deletingPathExtension))
                let report = try ZIPArchive.extract(archiveAt: archiveURL, to: extractDir)
                await MainActor.run {
                    statusMessage = report.rejected.isEmpty
                        ? "解压完成：\(report.extracted.count) 个文件"
                        : "解压完成：\(report.extracted.count) 个文件，拒绝 \(report.rejected.count) 个危险条目"
                }
            }
        }
    }

    private var renameSection: some View {
        GroupBox("批量重命名（先预览后执行，冲突会被拒绝）") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("模式", selection: $renameMode) {
                    ForEach(BatchRenameEngine.Mode.allCases, id: \.self) { mode in
                        Text(modeLabel(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch renameMode {
                case .pattern:
                    TextField("基础名", text: $renamePatternBase).textFieldStyle(.roundedBorder)
                case .replace:
                    HStack {
                        TextField("查找", text: $renameFind).textFieldStyle(.roundedBorder)
                        TextField("替换为", text: $renameReplacement).textFieldStyle(.roundedBorder)
                    }
                case .addPrefix:
                    TextField("前缀", text: $renamePrefix).textFieldStyle(.roundedBorder)
                case .addSuffix:
                    TextField("后缀", text: $renameSuffix).textFieldStyle(.roundedBorder)
                }

                HStack {
                    Picker("序号位数", selection: $renamePadding) {
                        ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .frame(width: 100)
                    Button("生成预览") { generateRenamePreview() }
                        .disabled(staged.isEmpty)
                    Button("执行重命名") { executeRename() }
                        .disabled(renamePlan == nil || renamePlan!.isEmpty)
                    Button("存为模板…") { saveTemplate() }
                        .disabled(staged.isEmpty)
                }

                if let plan = renamePlan {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.renames.prefix(8), id: \.from) { pair in
                            HStack(spacing: 6) {
                                Text(pair.from).font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption2)
                                Text(pair.to).font(.caption)
                            }
                        }
                        if plan.renames.count > 8 {
                            Text("…共 \(plan.renames.count) 条")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(8)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                }

                if !templates.isEmpty {
                    HStack {
                        Text("模板：").font(.caption)
                        ForEach(templates) { template in
                            Button(template.name) { applyTemplate(template) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                        Spacer()
                        Button("管理模板…") { manageTemplates() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func modeLabel(_ mode: BatchRenameEngine.Mode) -> String {
        switch mode {
        case .pattern: return "编号"
        case .replace: return "查找替换"
        case .addPrefix: return "加前缀"
        case .addSuffix: return "加后缀"
        }
    }

    // MARK: - 动作

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择处理结果的输出目录"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                outputDirectory = url
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            staged.append(contentsOf: panel.urls.map(StagedFile.init))
        }
    }

    private func guardLimits(_ files: [StagedFile]) -> Bool {
        for file in files {
            do {
                try FileStudioLimits.validate(file)
            } catch {
                statusMessage = String(describing: error)
                return false
            }
        }
        return true
    }

    private func runPDFMerge(_ pdfs: [StagedFile]) {
        guard guardLimits(pdfs) else { return }
        let urls = pdfs.map(\.url)
        let outputDir = outputDirectory
        Task {
            await TaskQueue.shared.enqueue(title: "合并 PDF（\(urls.count) 个）") { context in
                context.progress(0.2)
                let output = try PDFEngine.merge(sources: urls, destinationDirectory: outputDir)
                context.progress(0.9)
                try FileSafety.validateOutput(at: output)
                await MainActor.run { statusMessage = "合并完成：\(output.lastPathComponent)" }
            }
        }
    }

    private func runPDFSplit(_ pdfs: [StagedFile]) {
        guard let first = pdfs.first, guardLimits([first]) else { return }
        let url = first.url
        let outputDir = outputDirectory
        Task {
            await TaskQueue.shared.enqueue(title: "拆分 PDF：\(url.lastPathComponent)") { context in
                context.progress(0.2)
                let outputs = try PDFEngine.splitPages(source: url, destinationDirectory: outputDir)
                context.progress(0.9)
                for output in outputs { try FileSafety.validateOutput(at: output) }
                await MainActor.run { statusMessage = "拆分完成：\(outputs.count) 个文件" }
            }
        }
    }

    private func runPDFRotate(_ pdfs: [StagedFile]) {
        guard let first = pdfs.first, guardLimits([first]) else { return }
        let url = first.url
        let degrees = rotateDegrees
        let outputDir = outputDirectory
        Task {
            await TaskQueue.shared.enqueue(title: "旋转 PDF：\(url.lastPathComponent)") { _ in
                let output = try PDFEngine.rotate(
                    source: url, pages: [], degrees: degrees, destinationDirectory: outputDir)
                try FileSafety.validateOutput(at: output)
                await MainActor.run { statusMessage = "旋转完成：\(output.lastPathComponent)" }
            }
        }
    }

    private func runPDFExtract(_ pdfs: [StagedFile]) {
        guard let first = pdfs.first, guardLimits([first]) else { return }
        let url = first.url
        let pagesText = extractPagesText
        let outputDir = outputDirectory
        Task {
            await TaskQueue.shared.enqueue(title: "提取 PDF 页面：\(url.lastPathComponent)") { _ in
                let pages = try parsePageRanges(pagesText)
                let output = try PDFEngine.extractPages(
                    source: url, pages: pages, destinationDirectory: outputDir)
                try FileSafety.validateOutput(at: output)
                await MainActor.run { statusMessage = "提取完成：\(output.lastPathComponent)" }
            }
        }
    }

    private func runPDFOptimize(_ pdfs: [StagedFile]) {
        guard let first = pdfs.first, guardLimits([first]) else { return }
        let url = first.url
        let quality = optimizeQuality
        let scale = optimizeScale
        let outputDir = outputDirectory
        Task {
            await TaskQueue.shared.enqueue(title: "优化 PDF：\(url.lastPathComponent)") { _ in
                let report = try PDFEngine.optimize(
                    source: url, destinationDirectory: outputDir,
                    jpegQuality: quality, scale: scale)
                await MainActor.run {
                    let ratio = report.originalBytes > 0
                        ? Int(Double(report.optimizedBytes) / Double(report.originalBytes) * 100)
                        : 100
                    statusMessage = "优化完成：\(report.originalBytes.formatted(.byteCount(style: .memory))) → "
                        + "\(report.optimizedBytes.formatted(.byteCount(style: .memory)))（\(ratio)%）"
                        + (report.reachedTarget ? "" : "（未达目标体积，已如实标注）")
                }
            }
        }
    }

    /// 解析 "1,3-5" 格式页码（非隔离纯函数）。
    nonisolated private func parsePageRanges(_ text: String) throws -> [Int] {
        var pages: [Int] = []
        for part in text.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-") {
                let bounds = trimmed.split(separator: "-")
                guard bounds.count == 2,
                      let start = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
                      let end = Int(bounds[1].trimmingCharacters(in: .whitespaces)),
                      start <= end else {
                    throw DeskvanicError(.invalidInput, "页码范围无效：\(trimmed)")
                }
                pages.append(contentsOf: start...end)
            } else if let page = Int(trimmed) {
                pages.append(page)
            } else {
                throw DeskvanicError(.invalidInput, "页码无效：\(trimmed)")
            }
        }
        return pages
    }

    // MARK: - 重命名

    private func generateRenamePreview() {
        do {
            renamePlan = try BatchRenameEngine.plan(
                fileNames: staged.map { $0.url.lastPathComponent },
                mode: renameMode,
                patternBase: renamePatternBase,
                find: renameFind,
                replacement: renameReplacement,
                prefix: renamePrefix,
                suffix: renameSuffix,
                padding: renamePadding)
            statusMessage = renamePlan!.isEmpty ? "没有需要改名的文件" : "预览已生成（尚未执行）"
        } catch {
            renamePlan = nil
            statusMessage = String(describing: error)
        }
    }

    private func executeRename() {
        guard let plan = renamePlan, !plan.isEmpty else { return }
        let files = staged
        Task {
            await TaskQueue.shared.enqueue(title: "批量重命名（\(plan.renames.count) 个）") { _ in
                var renamed = 0
                for pair in plan.renames {
                    guard let file = files.first(where: { $0.url.lastPathComponent == pair.from }) else { continue }
                    let newURL = file.url.deletingLastPathComponent().appendingPathComponent(pair.to)
                    guard !FileManager.default.fileExists(atPath: newURL.path) else {
                        throw DeskvanicError(.fileWriteFailed, "目标已存在：\(pair.to)，已中止（已完成的改名保留）")
                    }
                    try FileManager.default.moveItem(at: file.url, to: newURL)
                    renamed += 1
                }
                await MainActor.run {
                    statusMessage = "重命名完成：\(renamed) 个"
                    staged = files.map { file in
                        if let pair = plan.renames.first(where: { $0.from == file.url.lastPathComponent }) {
                            return StagedFile(url: file.url.deletingLastPathComponent().appendingPathComponent(pair.to))
                        }
                        return file
                    }
                    renamePlan = nil
                }
            }
        }
    }

    private func saveTemplate() {
        let alert = NSAlert()
        alert.messageText = "保存重命名模板"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "模板名称"
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return }
        let template = RenameTemplate(
            name: input.stringValue, mode: renameMode,
            patternBase: renamePatternBase, find: renameFind, replacement: renameReplacement,
            prefix: renamePrefix, suffix: renameSuffix, padding: renamePadding)
        Task {
            var updated = await templateStore.load()
            updated.append(template)
            await templateStore.save(updated)
            templates = updated
            statusMessage = "模板已保存：\(template.name)"
        }
    }

    private func applyTemplate(_ template: RenameTemplate) {
        renameMode = template.mode
        renamePatternBase = template.patternBase
        renameFind = template.find
        renameReplacement = template.replacement
        renamePrefix = template.prefix
        renameSuffix = template.suffix
        renamePadding = template.padding
        generateRenamePreview()
    }

    private func manageTemplates() {
        Task {
            var updated = await templateStore.load()
            updated.removeAll()
            await templateStore.save(updated)
            templates = []
            statusMessage = "模板已清空"
        }
    }
}

struct StagedRow: View {
    let file: StagedFile
    let onRemove: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: kindIcon).font(.title3)
                }
            }
            .frame(width: 36, height: 36)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent).lineLimit(1)
                Text(file.fileSize.formatted(.byteCount(style: .memory))
                     + " · " + kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .task {
            generateThumbnail()
        }
    }

    private func generateThumbnail() {
        let url = file.url
        let size = CGSize(width: 72, height: 72)
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: 1,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            Task { @MainActor in
                thumbnail = image
            }
        }
    }

    private var kindIcon: String {
        switch file.kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .zip: return "doc.zipper"
        case .other: return "doc"
        }
    }

    private var kindLabel: String {
        switch file.kind {
        case .image: return "图片"
        case .pdf: return "PDF"
        case .zip: return "ZIP"
        case .other: return "文件"
        }
    }
}
