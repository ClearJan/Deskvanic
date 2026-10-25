import AppKit
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// Clean Manager 服务装配点。
@MainActor
public enum CleanServices {
    public static var database = Database(url: AppEnvironment.databaseURL)
    public static var auditLog = AuditLog(database: Database(url: AppEnvironment.databaseURL))
    public static var history = OrganizeHistoryStore(database: Database(url: AppEnvironment.databaseURL))

    public static func inject(database newDatabase: Database, auditLog newAudit: AuditLog) {
        CleanServices.database = newDatabase
        CleanServices.auditLog = newAudit
        CleanServices.history = OrganizeHistoryStore(database: newDatabase)
    }
}

/// Clean Manager 主界面。
public struct CleanToolView: View {
    @State private var bookmarks: [String: String] = [:]
    @State private var selectedRoot: String?
    @State private var diskUsage: CleanScanner.DiskUsage?
    @State private var bigFiles: [CleanScanner.BigFile] = []
    @State private var duplicateGroups: [CleanScanner.DuplicateGroup] = []
    @State private var similarGroups: [CleanScanner.SimilarImageGroup] = []
    @State private var scanning = false
    @State private var scanProgress: Double = 0
    @State private var statusMessage: String?
    @State private var organizePlan: OrganizeEngine.Plan?
    @State private var operations: [OrganizeHistoryStore.OperationRecord] = []
    @State private var organizeRule = OrganizeEngine.Rule.downloadsDefault()

    private let bookmarkStore = BookmarkStore()

    public init() {}

    public var body: some View {
        ToolContainer("整理与磁盘空间", subtitle: "Clean Manager · 扫描 → 建议 → 确认执行") {
            VStack(spacing: 0) {
                header
                if let message = statusMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        diskSection
                        organizeSection
                        duplicatesSection
                        similarSection
                        historySection
                    }
                    .padding(16)
                }
            }
        }
        .task { await loadBookmarks() }
    }

    // MARK: - 顶部

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(Array(bookmarks.sorted(by: { $0.value < $1.value })), id: \.key) { pair in
                    Button(pair.value) { Task { await selectRoot(key: pair.key) } }
                }
            } label: {
                Label(selectedRoot ?? "选择授权文件夹", systemImage: "folder.badge.gearshape")
                    .lineLimit(1)
            }
            Button("添加授权文件夹…") { addFolder() }
            Spacer()
            Button("重新扫描") { Task { await scan() } }
                .disabled(selectedRoot == nil || scanning)
            if scanning {
                ProgressView(value: scanProgress)
                    .frame(width: 120)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        Divider()
    }

    // MARK: - 磁盘与大文件

    private var diskSection: some View {
        GroupBox("磁盘与大文件") {
            VStack(alignment: .leading, spacing: 10) {
                if let usage = diskUsage {
                    let usedRatio = usage.totalBytes > 0
                        ? Double(usage.totalBytes - usage.freeBytes) / Double(usage.totalBytes) : 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(usage.volumeName).font(.headline)
                            Spacer()
                            Text("可用 \(usage.freeBytes.formatted(.byteCount(style: .memory))) / 共 \(usage.totalBytes.formatted(.byteCount(style: .memory)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView(value: usedRatio)
                            .progressViewStyle(.linear)
                            .tint(usedRatio > 0.9 ? .red : .accentColor)
                    }
                }
                if !bigFiles.isEmpty {
                    Text("最大的 \(bigFiles.count) 个文件").font(.subheadline.bold())
                    ForEach(bigFiles.prefix(10)) { file in
                        HStack {
                            Image(systemName: "doc")
                            Text(file.name).lineLimit(1)
                            Spacer()
                            Text(file.sizeBytes.formatted(.byteCount(style: .memory)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - 整理规则

    private var organizeSection: some View {
        GroupBox("自动整理（模拟运行 → 确认 → 执行，可恢复）") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("规则名称", text: $organizeRule.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Text("规则将文件按扩展名移动到根目录下的分类文件夹（图片/文档/音频/视频/压缩包/安装包）。执行前先模拟运行并显示冲突。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("模拟运行") { Task { await simulateOrganize() } }
                        .disabled(selectedRoot == nil || bigFiles.isEmpty)
                    Button("执行整理（\(organizePlan?.moves.count ?? 0) 项）") { Task { await executeOrganize() } }
                        .disabled(organizePlan == nil || organizePlan!.moves.isEmpty)
                    if let plan = organizePlan {
                        Text("计划移动 \(plan.moves.count) 个文件（\(plan.totalBytes.formatted(.byteCount(style: .memory)))），冲突 \(plan.conflicts.count) 个（将改名不覆盖），跳过 \(plan.skipped.count) 个")
                            .font(.caption)
                            .foregroundStyle(plan.conflicts.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                }
                if let plan = organizePlan, !plan.skipped.isEmpty {
                    ForEach(plan.skipped.prefix(5), id: \.0) { path, reason in
                        HStack(spacing: 6) {
                            Image(systemName: "minus.circle").font(.caption)
                            Text("\((path as NSString).lastPathComponent) — \(reason)")
                                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - 重复与相似

    private var duplicatesSection: some View {
        GroupBox("完全重复文件（逐字节 SHA-256 校验，非名称/大小猜测）") {
            VStack(alignment: .leading, spacing: 10) {
                if duplicateGroups.isEmpty {
                    Text(duplicateGroups.isEmpty && !bigFiles.isEmpty ? "未发现完全重复" : "扫描后显示")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(Array(duplicateGroups.prefix(8).enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(group.files.count) 个相同文件 · 每个 \(group.files[0].sizeBytes.formatted(.byteCount(style: .memory)))")
                                .font(.callout.bold())
                            Spacer()
                            Button("移除多余（保留最早）") {
                                Task { await trashDuplicates(group) }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                        ForEach(group.files, id: \.path) { file in
                            HStack {
                                Image(systemName: file.path == group.keeperPath ? "checkmark.seal" : "doc")
                                    .foregroundStyle(file.path == group.keeperPath ? .green : .secondary)
                                Text(file.path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .padding(6)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var similarSection: some View {
        GroupBox("相似图片（感知哈希近邻，与完全重复使用不同检测定义）") {
            VStack(alignment: .leading, spacing: 10) {
                if similarGroups.isEmpty {
                    Text(similarGroups.isEmpty && !bigFiles.isEmpty ? "未发现视觉相似的图片组" : "扫描后显示")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(Array(similarGroups.prefix(5).enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("锚点：\((group.anchor.path as NSString).lastPathComponent)")
                            .font(.callout.bold())
                        ForEach(group.similar, id: \.file.path) { item in
                            HStack {
                                Image(systemName: "photo")
                                Text((item.file.path as NSString).lastPathComponent)
                                    .font(.caption).lineLimit(1)
                                Spacer()
                                Text("差异度 \(item.hammingDistance)/64")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text("相似 ≠ 相同：请在访达中确认后再手动处理（本工具不自动删除相似图片）。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(6)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var historySection: some View {
        GroupBox("操作记录（审计）") {
            VStack(alignment: .leading, spacing: 6) {
                if operations.isEmpty {
                    Text("暂无操作记录").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(operations.prefix(10)) { record in
                    HStack {
                        Image(systemName: record.outcome == "ok" ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(record.outcome == "ok" ? .green : .red)
                        Text(record.subject ?? record.action)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(record.ts).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - 动作

    private func loadBookmarks() async {
        var map: [String: String] = [:]
        for key in await bookmarkStore.keys where key.hasPrefix("clean-") {
            if let url = await bookmarkStore.resolve(key: key) {
                map[key] = url.path
            }
            await bookmarkStore.endAccess(key: key)
        }
        bookmarks = map
        if selectedRoot == nil, let first = map.first {
            await selectRoot(key: first.key)
        }
    }

    private func selectRoot(key: String) async {
        let bookmarkStore = self.bookmarkStore
        selectedRoot = bookmarks[key]
        if let url = await bookmarkStore.resolve(key: key) {
            diskUsage = CleanScanner.diskUsage(at: url)
            organizePlan = nil
        }
        await bookmarkStore.endAccess(key: key)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择允许 Clean Manager 扫描与整理的文件夹"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let key = "clean-\(UUID().uuidString.prefix(8))"
            Task {
                try? await bookmarkStore.saveBookmark(for: url, key: key)
                await loadBookmarks()
            }
        }
    }

    private func scan() async {
        guard let root = selectedRoot else { return }
        scanning = true
        defer { scanning = false }
        let rootURL = URL(fileURLWithPath: root)
        // 目录递归在后台执行，避免大目录/网络卷阻塞主线程（审计 #1）
        bigFiles = await Task.detached(priority: .userInitiated) {
            CleanScanner.findBigFiles(in: rootURL)
        }.value
        scanProgress = 0.4
        duplicateGroups = await CleanScanner.findExactDuplicates(files: bigFiles) { fraction in
            Task { @MainActor in scanProgress = 0.4 + fraction * 0.4 }
        }
        scanProgress = 0.8
        similarGroups = await CleanScanner.findSimilarImages(in: bigFiles) { fraction in
            Task { @MainActor in scanProgress = 0.8 + fraction * 0.2 }
        }
        scanProgress = 1
        organizePlan = nil
        statusMessage = "扫描完成：\(bigFiles.count) 个大文件，\(duplicateGroups.count) 组重复，\(similarGroups.count) 组相似"
    }

    private func simulateOrganize() async {
        guard let root = selectedRoot else { return }
        let files = bigFiles.map(\.path)
        let organized = (try? await CleanServices.history.organizedPaths(root: root)) ?? Set()
        organizePlan = OrganizeEngine.plan(files: files, in: root, rule: organizeRule, alreadyOrganized: organized)
        statusMessage = "模拟运行完成，请检查计划后确认执行"
    }

    private func executeOrganize() async {
        guard let root = selectedRoot, let plan = organizePlan else { return }
        // 危险操作确认
        let alert = NSAlert()
        alert.messageText = "执行整理？"
        alert.informativeText = "将移动 \(plan.moves.count) 个文件到分类文件夹（同卷直接移动，跨卷复制后原文件进废纸篓）。原文件路径会登记，防止重复触发。"
        alert.addButton(withTitle: "执行")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = await OrganizeEngine.execute(plan, in: root, audit: CleanServices.auditLog)
        // 登记成功移动的文件
        let failedSources = Set(result.failures.map(\.source))
        let movedSources = Set(plan.moves.map(\.source)).subtracting(failedSources)
        for source in movedSources {
            if let move = plan.moves.first(where: { $0.source == source }) {
                try? await CleanServices.history.recordOrganized(
                    originalPath: source, newPath: move.target, root: root)
            }
        }
        operations = (try? await CleanServices.history.recentOperations()) ?? []
        statusMessage = "执行完成：移动 \(result.movedCount) 个，失败 \(result.failedCount) 个"
        organizePlan = nil
        await scan()
    }

    private func trashDuplicates(_ group: CleanScanner.DuplicateGroup) async {
        let keeper = group.keeperPath
        let toTrash = group.files.filter { $0.path != keeper }
        let alert = NSAlert()
        alert.messageText = "将 \(toTrash.count) 个重复文件移入废纸篓？"
        alert.informativeText = "保留：\(keeper)\n移入废纸篓的文件可从废纸篓恢复。"
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var trashed = 0
        for file in toTrash {
            do {
                _ = try await FileSafety.moveToTrash(URL(fileURLWithPath: file.path))
                await CleanServices.auditLog.record(
                    action: "clean.duplicate.trash", subject: file.path, outcome: "ok",
                    detail: "keeper: \(keeper)")
                trashed += 1
            } catch {
                await CleanServices.auditLog.record(
                    action: "clean.duplicate.trash", subject: file.path, outcome: "failed",
                    detail: String(describing: error))
            }
        }
        statusMessage = "已移入废纸篓 \(trashed) 个"
        await scan()
    }
}
