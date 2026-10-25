import AppKit
import Foundation
import DeskvanicCore

/// 剪贴板监控器：轮询 NSPasteboard.changeCount，变化时提取内容并入库。
///
/// 设计与限制（如实声明）：
/// - macOS 无公开 API 返回剪贴板内容的"来源应用"。采用启发式：取变化时刻的前台应用
///   （NSWorkspace.frontmostApplication），归属可能不准确，仅供"排除应用"功能使用。
/// - 系统对"私密剪贴板"（如密码管理器标记的 org.nspasteboard.ConcealedType）不提供
///   公开读取限制；监控器主动跳过 Concealed/Transient 标记类型，不保存这类内容。
/// - 轮询间隔 0.5s；监控在后台 Task 执行，不占用主线程。
@MainActor
public final class ClipboardMonitor: ObservableObject {
    /// 监控器从面板读取内容所需的抽象（测试注入用）。
    public protocol Reading: Sendable {
        func currentChangeCount() -> Int
        func readSnapshot() -> ClipClassifier.Snapshot?
        func readImageData() -> Data?
    }

    public struct NSPasteboardReader: Reading {
        public init() {}

        public func currentChangeCount() -> Int {
            NSPasteboard.general.changeCount
        }

        public func readSnapshot() -> ClipClassifier.Snapshot? {
            let pasteboard = NSPasteboard.general
            let types = pasteboard.types ?? []

            // 尊重私密/瞬态标记：不保存
            let concealed = types.contains { $0.rawValue.hasPrefix("org.nspasteboard.Concealed") }
            let transient = types.contains { $0.rawValue.hasPrefix("org.nspasteboard.Transient") }
                || types.contains(NSPasteboard.PasteboardType("com.apple.is.transient"))
            if concealed || transient { return nil }

            let utf8Text = pasteboard.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
            var fileURLs: [String] = []
            if let fileURLObjects = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] {
                fileURLs = fileURLObjects.map(\.path)
            }
            let urlText = pasteboard.string(forType: NSPasteboard.PasteboardType("public.url"))
                ?? (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString
            var imageBytes = 0
            if types.contains(.png) || types.contains(.tiff) {
                if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
                    imageBytes = data.count
                }
            }
            return ClipClassifier.Snapshot(
                types: types.map(\.rawValue),
                utf8Text: utf8Text,
                fileURLs: fileURLs,
                urlText: urlText,
                imageSizeBytes: imageBytes)
        }

        public func readImageData() -> Data? {
            NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff)
        }
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastError: String?

    private let store: ClipStore
    private let settings: () -> ClipVaultSettings
    private let reader: any Reading
    private var pollTask: Task<Void, Never>?
    private var lastChangeCount: Int
    /// 变化时刻的前台应用（启发式来源归属）。
    private var frontmostBundleID: String?

    public init(
        store: ClipStore,
        settings: @escaping () -> ClipVaultSettings,
        reader: any Reading = NSPasteboardReader()
    ) {
        self.store = store
        self.settings = settings
        self.reader = reader
        self.lastChangeCount = reader.currentChangeCount()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in
                    self?.frontmostBundleID = app?.bundleIdentifier
                }
            }
    }

    public func start() {
        guard pollTask == nil else { return }
        isRunning = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        isRunning = false
    }

    /// 单次轮询：变化时提取并入库。公开便于测试（配合注入 reader）。
    public func pollOnce() async {
        guard settings().enabled else { return }
        if settings().pauseMonitoring { return }
        let count = reader.currentChangeCount()
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        guard let snapshot = reader.readSnapshot() else { return }
        let classification = ClipClassifier.classify(snapshot)

        // 排除应用（启发式来源归属）
        let config = settings()
        if let bundleID = frontmostBundleID, config.excludedBundleIDs.contains(bundleID) {
            return
        }

        do {
            switch classification {
            case .image(let sizeBytes):
                guard let data = reader.readImageData() else { return }
                // 图片编码与落盘移出主线程（审计 P3 #20：粘贴板读取必须在主线程，写盘不必）
                let savedPath: URL = try await Task.detached(priority: .userInitiated) {
                    try await self.store.saveImage(data)
                }.value
                let entry = ClipEntry(
                    kind: .image,
                    filePath: savedPath.path,
                    preview: "图片 \(sizeBytes.formatted(.byteCount(style: .memory)))",
                    byteSize: sizeBytes,
                    sourceApp: frontmostBundleID)
                _ = try await store.insert(entry)
            case .files(let paths):
                let preview = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
                let entry = ClipEntry(
                    kind: .files,
                    contentText: paths.joined(separator: "\n"),
                    preview: String(preview.prefix(120)),
                    byteSize: paths.count,
                    sourceApp: frontmostBundleID)
                _ = try await store.insert(entry)
            case .url(let urlString):
                let entry = ClipEntry(
                    kind: .url,
                    contentText: urlString,
                    preview: urlString,
                    byteSize: urlString.utf8.count,
                    sourceApp: frontmostBundleID)
                _ = try await store.insert(entry)
            case .text(let text):
                // 超长文本保护：>2MB 不入库（防内存膨胀与 FTS 膨胀）——审计 #3
                guard text.utf8.count <= 2_000_000 else { return }
                let entry = ClipEntry(
                    kind: .text,
                    contentText: text,
                    preview: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)),
                    byteSize: text.utf8.count,
                    sourceApp: frontmostBundleID)
                _ = try await store.insert(entry)
            case .ignored:
                return
            }
            lastError = nil
            await applyRetention()
        } catch {
            lastError = String(describing: error)
            Log.error("剪贴板入库失败: \(String(describing: error))", category: .clipboard)
        }
    }

    /// 应用自动清理策略。
    public func applyRetention() async {
        let config = settings()
        guard let entries = try? await store.entries(limit: 5000) else { return }
        let stale = ClipRetentionPolicy.staleIDs(
            entries: entries, now: Date(),
            retentionDays: config.retentionDays, maxItems: config.maxItems)
        if !stale.isEmpty {
            try? await store.delete(ids: stale)
        }
    }
}
