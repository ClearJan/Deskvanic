import Foundation
import Testing
import DeskvanicCore
@testable import DeskvanicCommandCenter

@Suite("CommandRegistry")
struct CommandRegistryTests {
    @Test func registerSearchAndDedup() async {
        let registry = CommandRegistry()
        await registry.register(CommandItem(id: "tool.a", title: "截图工具", subtitle: "打开工具", kind: .tool, icon: "camera", payload: "capture"))
        await registry.register(CommandItem(id: "tool.b", title: "剪贴板历史", subtitle: "打开工具", kind: .tool, icon: "doc.on.clipboard", payload: "clip"))
        // 重复 ID 覆盖
        await registry.register(CommandItem(id: "tool.a", title: "截图与识别", subtitle: "打开工具", kind: .tool, icon: "camera", payload: "capture"))

        let all = await registry.staticCommands
        #expect(all.count == 2)
        #expect(all.first { $0.id == "tool.a" }?.title == "截图与识别")

        let results = await registry.search(query: "截图", limit: 10)
        #expect(results.first?.command.id == "tool.a")

        let none = await registry.search(query: "不存在的命令")
        #expect(none.isEmpty)
    }

    @Test func dynamicProviderResults() async {
        let registry = CommandRegistry()
        await registry.registerProvider(id: "clips") { query in
            [
                CommandItem(id: "clip.1", title: "会议记录 \(query)", subtitle: "剪贴板", kind: .clip, icon: "doc.on.clipboard", payload: "1"),
            ]
        }
        let results = await registry.search(query: "会议", limit: 20)
        #expect(results.contains { $0.command.id == "clip.1" })
        // 空查询不调用 provider
        let empty = await registry.search(query: "")
        #expect(empty.isEmpty)
        await registry.removeProvider(id: "clips")
        let afterRemove = await registry.search(query: "会议")
        #expect(afterRemove.isEmpty)
    }
}

@Suite("AppLauncher")
struct AppLauncherTests {
    @Test func scanFindsSystemApps() async {
        let launcher = AppLauncher()
        let apps = await launcher.refreshIfNeeded(force: true)
        #expect(!apps.isEmpty)
        // 系统应用至少能找到几个常见应用（TextEdit 在 /System/Applications）
        #expect(apps.contains { $0.name.contains("TextEdit") || $0.name.contains("文本编辑") })
        // 用真实发现的应用名做模糊搜索探针（对系统语言免疫：中英文名均应命中）
        guard let probe = apps.first?.name else { Issue.record("无应用可探测"); return }
        let search = await launcher.search(String(probe.prefix(2)), limit: 20)
        #expect(!search.isEmpty)
    }

    @Test func searchEmptyQueryReturnsPrelimited() async {
        let launcher = AppLauncher()
        let apps = await launcher.search("", limit: 5)
        #expect(apps.count <= 5)
    }
}

@Suite("CommandUsageStore")
struct CommandUsageStoreTests {
    private func makeStore() async throws -> CommandUsageStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = Database(url: dir.appendingPathComponent("t.sqlite"))
        try await db.open()
        try await db.migrate(DeskvanicSchema.migrations)
        return CommandUsageStore(database: db)
    }

    @Test func recordAndPersistRoundtrip() async throws {
        let store = try await makeStore()
        await store.recordExecution(commandID: "tool.capture", title: "截图")
        await store.recordExecution(commandID: "tool.capture", title: "截图")
        await store.recordExecution(commandID: "app.safari", title: "Safari")
        let recent = await store.recentCommands()
        #expect(recent.count == 2)
        // 最后记录的 app.safari 时间最新，按最近使用排序应排最前
        #expect(recent.first == "app.safari")

        // 收藏
        await store.toggleFavorite(commandID: "app.safari")
        let favorites = await store.favorites()
        #expect(favorites == ["app.safari"])
        await store.toggleFavorite(commandID: "app.safari")
        let favoritesAfter = await store.favorites()
        #expect(favoritesAfter.isEmpty)
    }

    @Test func recentListCapped() async throws {
        let store = try await makeStore()
        for i in 0..<30 {
            await store.recordExecution(commandID: "cmd.\(i)", title: "命令 \(i)")
        }
        let recent = await store.recentCommands()
        #expect(recent.count == 20)
    }
}

@Suite("FileSearcher")
struct FileSearcherTests {
    @Test func scanRespectsDepthAndSymlinks() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("deep/1/2/3/4/5"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("a/loop"), withDestinationURL: dir)

        let searcher = FileSearcher(bookmarks: BookmarkStore())
        let hits = await searcher.scanDirectory(dir.path, maxDepth: 4, maxEntries: 500)
        let names = Set(hits.map(\.name))
        #expect(names.contains("a"))
        #expect(names.contains("b"))
        #expect(names.contains("loop"))   // 链接本身收录
        // 深度 4 内不应看到 4/5 层的深层目录（depth 从 1 计）
        #expect(!names.contains("5"))
        // 无限循环防护：loop 链接不会被展开成死循环（测试在有限时间内完成即通过）
    }

    @Test func emptyQueryReturnsEmpty() async {
        let searcher = FileSearcher(bookmarks: BookmarkStore())
        let results = await searcher.search("")
        #expect(results.isEmpty)
    }
}
