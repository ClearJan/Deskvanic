import Foundation
import Testing
import DeskvanicCore
@testable import DeskvanicClipVault

@Suite("ClipClassifier")
struct ClipClassifierTests {
    private func make(_ types: [String], utf8: String? = nil, files: [String] = [], url: String? = nil, imageBytes: Int = 0) -> ClipClassifier.Snapshot {
        ClipClassifier.Snapshot(types: types, utf8Text: utf8, fileURLs: files, urlText: url, imageSizeBytes: imageBytes)
    }

    @Test func imageBeatsEverything() {
        let result = ClipClassifier.classify(make(
            ["public.png", "public.utf8-plain-text"], utf8: "hello", imageBytes: 1024))
        #expect(result == .image(sizeBytes: 1024))
    }

    @Test func tiffCountsWithoutPNG() {
        let result = ClipClassifier.classify(make(["public.tiff"], imageBytes: 512))
        #expect(result == .image(sizeBytes: 512))
    }

    @Test func fileURLs() {
        let result = ClipClassifier.classify(make(
            ["public.file-url"], files: ["/tmp/a.txt", "/tmp/b.pdf"]))
        #expect(result == .files(paths: ["/tmp/a.txt", "/tmp/b.pdf"]))
    }

    @Test func explicitURLType() {
        let result = ClipClassifier.classify(make(
            ["public.url"], url: "https://example.com/page"))
        #expect(result == .url("https://example.com/page"))
    }

    @Test func plainTextThatLooksLikeURL() {
        let result = ClipClassifier.classify(make(
            ["public.utf8-plain-text"], utf8: "https://example.com"))
        #expect(result == .url("https://example.com"))
    }

    @Test func plainText() {
        let result = ClipClassifier.classify(make(
            ["public.utf8-plain-text"], utf8: "普通文本内容"))
        #expect(result == .text("普通文本内容"))
    }

    @Test func javascriptURLEnemyDowngradesToText() {
        // javascript: 不在允许 scheme 内 → 降级为文本（防误开）
        let result = ClipClassifier.classify(make(
            ["public.utf8-plain-text"], utf8: "javascript:alert(1)"))
        if case .text = result { /* 期望文本 */ } else {
            Issue.record("javascript: URL 应降级为文本，实际 \(result)")
        }
    }

    @Test func emptyIsIgnored() {
        #expect(ClipClassifier.classify(make(["public.utf8-plain-text"], utf8: "")) == .ignored)
        #expect(ClipClassifier.classify(make([])) == .ignored)
    }
}

@Suite("ClipRetentionPolicy")
struct ClipRetentionPolicyTests {
    private func entry(_ id: String, daysAgo: Double, pinned: Bool = false, favorite: Bool = false) -> ClipEntry {
        ClipEntry(
            id: id, kind: .text, contentText: id, preview: id,
            pinned: pinned, favorite: favorite,
            createdAt: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    @Test func expiredUnprotectedEntriesDeleted() {
        let entries = [
            entry("old", daysAgo: 40),
            entry("new", daysAgo: 1),
            entry("pinned-old", daysAgo: 400, pinned: true),
            entry("fav-old", daysAgo: 400, favorite: true),
        ]
        let stale = ClipRetentionPolicy.staleIDs(entries: entries, now: Date(), retentionDays: 30, maxItems: 0)
        #expect(stale == ["old"])
    }

    @Test func capacityTrimsOldestUnprotected() {
        let entries = (0..<10).map { entry("e\($0)", daysAgo: Double(10 - $0)) }
        let stale = ClipRetentionPolicy.staleIDs(entries: entries, now: Date(), retentionDays: 0, maxItems: 3)
        // 保留最新 3 条（e9 e8 e7），删除其余
        #expect(stale.count == 7)
        #expect(!stale.contains("e9") && !stale.contains("e8") && !stale.contains("e7"))
        #expect(stale.contains("e0") && stale.contains("e6"))
    }

    @Test func pinnedNotCountedAgainstCapacity() {
        let entries = [
            entry("p1", daysAgo: 10, pinned: true),
            entry("p2", daysAgo: 9, pinned: true),
            entry("a", daysAgo: 8),
            entry("b", daysAgo: 7),
            entry("c", daysAgo: 6),
        ]
        let stale = ClipRetentionPolicy.staleIDs(entries: entries, now: Date(), retentionDays: 0, maxItems: 3)
        // 固定条目不占容量：a b c 全部保留
        #expect(stale.isEmpty)
    }

    @Test func zeroLimitsMeanNoOp() {
        let entries = [entry("x", daysAgo: 1000)]
        #expect(ClipRetentionPolicy.staleIDs(entries: entries, now: Date(), retentionDays: 0, maxItems: 0).isEmpty)
    }
}

@Suite("ClipStore")
struct ClipStoreTests {
    private func makeStore() async throws -> ClipStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-clips-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = Database(url: dir.appendingPathComponent("t.sqlite"))
        try await db.open()
        try await db.migrate(DeskvanicSchema.migrations + [ClipVaultSchema.migration])
        return ClipStore(
            database: db, index: SearchIndex(database: db),
            imagesDirectory: dir.appendingPathComponent("imgs"))
    }

    @Test func insertListAndDelete() async throws {
        let store = try await makeStore()
        _ = try await store.insert(ClipEntry(kind: .text, contentText: "第一段内容", preview: "第一段内容"))
        _ = try await store.insert(ClipEntry(kind: .url, contentText: "https://a.com", preview: "https://a.com"))
        let all = try await store.entries()
        #expect(all.count == 2)
        try await store.delete(id: all[0].id)
        #expect(try await store.count() == 1)
    }

    @Test func duplicateRefreshesInsteadOfInserting() async throws {
        let store = try await makeStore()
        _ = try await store.insert(ClipEntry(kind: .text, contentText: "重复内容", preview: "重复内容"))
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let second = ClipEntry(kind: .text, contentText: "重复内容", preview: "重复内容")
        let (_, inserted) = try await store.insert(second)
        #expect(!inserted)
        #expect(try await store.count() == 1)
        // 不同内容正常新增
        let (_, insertedDifferent) = try await store.insert(ClipEntry(kind: .text, contentText: "不同内容", preview: "不同内容"))
        #expect(insertedDifferent)
        #expect(try await store.count() == 2)
    }

    @Test func fullTextSearchViaFTS() async throws {
        let store = try await makeStore()
        _ = try await store.insert(ClipEntry(kind: .text, contentText: "项目周报 记录会议内容", preview: "项目周报"))
        _ = try await store.insert(ClipEntry(kind: .text, contentText: "grocery list milk", preview: "grocery"))
        let chinese = try await store.search("周报")
        #expect(chinese.count == 1)
        let english = try await store.search("milk")
        #expect(english.count == 1)
        let none = try await store.search("xyzzy")
        #expect(none.isEmpty)
    }

    @Test func pinAndFavoritePersist() async throws {
        let store = try await makeStore()
        _ = try await store.insert(ClipEntry(kind: .text, contentText: "x", preview: "x"))
        let entry = try await store.entries()[0]
        try await store.setPinned(id: entry.id, pinned: true)
        try await store.setFavorite(id: entry.id, favorite: true)
        let reloaded = try await store.entry(id: entry.id)
        #expect(reloaded?.pinned == true)
        #expect(reloaded?.favorite == true)
    }

    @Test func deleteAllKeepsProtected() async throws {
        let store = try await makeStore()
        _ = try await store.insert(ClipEntry(kind: .text, contentText: "普通", preview: "普通"))
        let protected = ClipEntry(kind: .text, contentText: "重要", preview: "重要", pinned: true)
        _ = try await store.insert(protected)
        try await store.deleteAll(clearProtected: false)
        let remaining = try await store.entries()
        #expect(remaining.count == 1 && remaining[0].pinned)
        try await store.deleteAll(clearProtected: true)
        #expect(try await store.count() == 0)
    }

    @Test func templatesCRUD() async throws {
        let store = try await makeStore()
        try await store.saveTemplate(name: "问候", content: "你好，{name}！")
        let templates = try await store.templates()
        #expect(templates.count == 1 && templates[0].content.contains("{name}"))
        try await store.deleteTemplate(id: templates[0].id)
        #expect(try await store.templates().isEmpty)
        // 空名拒绝
        await #expect(throws: DeskvanicError.self) {
            try await store.saveTemplate(name: "", content: "x")
        }
    }
}

@Suite("ClipboardMonitor")
struct ClipboardMonitorTests {
    /// 可注入的假读取器。
    final class FakeReader: ClipboardMonitor.Reading, @unchecked Sendable {
        private let lock = NSLock()
        private var _changeCount = 0
        private var _snapshot: ClipClassifier.Snapshot?
        private var _imageData: Data?

        var changeCount: Int {
            get { lock.lock(); defer { lock.unlock() }; return _changeCount }
            set { lock.lock(); _changeCount = newValue; lock.unlock() }
        }
        var snapshot: ClipClassifier.Snapshot? {
            get { lock.lock(); defer { lock.unlock() }; return _snapshot }
            set { lock.lock(); _snapshot = newValue; lock.unlock() }
        }
        var imageData: Data? {
            get { lock.lock(); defer { lock.unlock() }; return _imageData }
            set { lock.lock(); _imageData = newValue; lock.unlock() }
        }

        func currentChangeCount() -> Int { changeCount }
        func readSnapshot() -> ClipClassifier.Snapshot? { snapshot }
        func readImageData() -> Data? { imageData }
    }

    private func makeMonitor(reader: FakeReader, config: ClipVaultSettings) async -> (ClipboardMonitor, ClipStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-mon-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = Database(url: dir.appendingPathComponent("t.sqlite"))
        try? await db.open()
        try? await db.migrate(DeskvanicSchema.migrations + [ClipVaultSchema.migration])
        let store = ClipStore(database: db, index: SearchIndex(database: db), imagesDirectory: dir.appendingPathComponent("imgs"))
        let monitor = await MainActor.run {
            ClipboardMonitor(store: store, settings: { config }, reader: reader)
        }
        return (monitor, store)
    }

    @Test func textCaptureOnCountChange() async {
        let reader = FakeReader()
        let (monitor, store) = await makeMonitor(reader: reader, config: ClipVaultSettings())
        reader.snapshot = ClipClassifier.Snapshot(
            types: ["public.utf8-plain-text"], utf8Text: "监控文本", fileURLs: [], urlText: nil, imageSizeBytes: 0)
        reader.changeCount = 42
        await monitor.pollOnce()
        let entries = (try? await store.entries()) ?? []
        #expect(entries.count == 1)
        #expect(entries.first?.contentText == "监控文本")
    }

    @Test func noChangeMeansNoInsert() async {
        let reader = FakeReader()
        let (monitor, store) = await makeMonitor(reader: reader, config: ClipVaultSettings())
        await monitor.pollOnce()   // 无变化
        #expect((try? await store.count()) == 0)
    }

    @Test func pausedMonitorIgnoresChanges() async {
        let reader = FakeReader()
        var config = ClipVaultSettings()
        config.pauseMonitoring = true
        let (monitor, store) = await makeMonitor(reader: reader, config: config)
        reader.snapshot = ClipClassifier.Snapshot(
            types: ["public.utf8-plain-text"], utf8Text: "被忽略", fileURLs: [], urlText: nil, imageSizeBytes: 0)
        reader.changeCount = 7
        await monitor.pollOnce()
        #expect((try? await store.count()) == 0)
    }

    @Test func disabledMonitorIgnoresChanges() async {
        let reader = FakeReader()
        var config = ClipVaultSettings()
        config.enabled = false
        let (monitor, store) = await makeMonitor(reader: reader, config: config)
        reader.snapshot = ClipClassifier.Snapshot(
            types: ["public.utf8-plain-text"], utf8Text: "禁用中", fileURLs: [], urlText: nil, imageSizeBytes: 0)
        reader.changeCount = 9
        await monitor.pollOnce()
        #expect((try? await store.count()) == 0)
    }

    @Test func retentionAppliedAfterCapture() async {
        let reader = FakeReader()
        var config = ClipVaultSettings()
        config.retentionDays = 30
        config.maxItems = 2
        let (monitor, store) = await makeMonitor(reader: reader, config: config)

        // 预置 3 条旧记录
        for i in 0..<3 {
            _ = try? await store.insert(ClipEntry(kind: .text, contentText: "旧\(i)", preview: "旧\(i)"))
        }
        reader.snapshot = ClipClassifier.Snapshot(
            types: ["public.utf8-plain-text"], utf8Text: "新内容", fileURLs: [], urlText: nil, imageSizeBytes: 0)
        reader.changeCount = 100
        await monitor.pollOnce()
        // maxItems=2 → 旧记录被裁剪，只剩最新 2 条
        let count = (try? await store.count()) ?? 0
        #expect(count == 2)
    }
}
