import Foundation
import Testing
import DeskvanicCore
@testable import DeskvanicVault

@Suite("VaultStore")
struct VaultStoreTests {
    private func makeStore() async throws -> VaultStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = Database(url: dir.appendingPathComponent("t.sqlite"))
        try await db.open()
        try await db.migrate(DeskvanicSchema.migrations + [VaultSchema.migration])
        return VaultStore(database: db, index: SearchIndex(database: db))
    }

    @Test func addAndFilterByKind() async throws {
        let store = try await makeStore()
        try await store.add(VaultItem(kind: .text, title: "会议纪要", contentText: "讨论了发布计划"))
        try await store.add(VaultItem(kind: .url, title: "example", contentText: "https://example.com"))
        try await store.add(VaultItem(kind: .image, title: "截图"))

        let all = try await store.items()
        #expect(all.count == 3)
        let texts = try await store.items(filter: .init(kind: .text))
        #expect(texts.count == 1 && texts[0].title == "会议纪要")
        let urls = try await store.items(filter: .init(kind: .url))
        #expect(urls.count == 1)
    }

    @Test func fullTextSearchFindsContentAndOCR() async throws {
        let store = try await makeStore()
        try await store.add(VaultItem(kind: .text, title: "周报", contentText: "项目里程碑更新"))
        try await store.add(VaultItem(kind: .image, title: "扫描件", ocrText: "发票号码 12345678"))

        let hits1 = try await store.items(filter: .init(query: "里程碑"))
        #expect(hits1.count == 1 && hits1[0].title == "周报")
        let hits2 = try await store.items(filter: .init(query: "12345678"))
        #expect(hits2.count == 1 && hits2[0].title == "扫描件")
        let none = try await store.items(filter: .init(query: "完全无关词"))
        #expect(none.isEmpty)
    }

    @Test func tagsReplaceAndFilter() async throws {
        let store = try await makeStore()
        var item = VaultItem(kind: .text, title: "带标签", tags: ["工作", "重要"])
        try await store.add(item)
        var tags = try await store.allTags()
        #expect(Set(tags) == Set(["工作", "重要"]))

        // 替换标签
        item.tags = ["工作"]
        try await store.update(item)
        tags = try await store.allTags()
        #expect(tags == ["工作"])
        let byTag = try await store.items(filter: .init(tag: "工作"))
        #expect(byTag.count == 1)
        let missing = try await store.items(filter: .init(tag: "重要"))
        #expect(missing.isEmpty)
    }

    @Test func favoriteFilterAndToggle() async throws {
        let store = try await makeStore()
        try await store.add(VaultItem(kind: .text, title: "普通"))
        try await store.add(VaultItem(kind: .text, title: "收藏的", favorite: true))
        let favorites = try await store.items(filter: .init(favoriteOnly: true))
        #expect(favorites.count == 1 && favorites[0].title == "收藏的")
    }

    @Test func referencedFileStatusReflectsExistence() async throws {
        let store = try await makeStore()
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-ref-\(UUID().uuidString).txt")
        try "data".write(to: tempFile, atomically: true, encoding: .utf8)

        let item = VaultItem(
            kind: .file, title: "引用文件",
            referencePath: tempFile.path, storageMode: .referenced)
        try await store.add(item)
        #expect(item.fileStatus == .available)

        try FileManager.default.removeItem(at: tempFile)
        #expect(item.fileStatus == .missing)
        // 复制模式文件被删也报 missing
        let copied = VaultItem(
            kind: .file, title: "复制文件",
            storagePath: "/nonexistent/path.bin", storageMode: .copied)
        #expect(copied.fileStatus == .missing)
        // 无文件条目不适用
        #expect(VaultItem(kind: .text, title: "纯文本").fileStatus == .notApplicable)
    }

    @Test func deleteRemovesIndexAndTags() async throws {
        let store = try await makeStore()
        let item = VaultItem(kind: .text, title: "待删除", contentText: "索引内容xyzzy", tags: ["临时"])
        try await store.add(item)
        #expect(try await store.items(filter: .init(query: "xyzzy")).count == 1)
        try await store.delete(id: item.id)
        #expect(try await store.items().isEmpty)
        #expect(try await store.items(filter: .init(query: "xyzzy")).isEmpty)
        #expect(try await store.allTags().isEmpty)
    }

    @Test func rebuildIndexRestoresSearch() async throws {
        let store = try await makeStore()
        try await store.add(VaultItem(kind: .text, title: "重建前", contentText: "唯一标记词qwerty"))
        try await store.rebuildIndex()
        let hits = try await store.items(filter: .init(query: "qwerty"))
        #expect(hits.count == 1)
    }
}
