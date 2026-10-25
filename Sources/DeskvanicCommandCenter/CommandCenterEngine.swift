import Foundation
import DeskvanicCore

/// 命令中心引擎：统一汇总命令、应用、文件、资料检索结果，
/// 附加最近使用与收藏，输出单一排序候选列表。全部异步，不阻塞主线程。
public actor CommandCenterEngine {
    public static let shared = CommandCenterEngine()

    private let registry: CommandRegistry
    private let appLauncher: AppLauncher
    private let fileSearcher: FileSearcher
    private let usage: CommandUsageStore
    private let searchIndex: SearchIndex?

    public init(
        registry: CommandRegistry = .shared,
        appLauncher: AppLauncher = .shared,
        fileSearcher: FileSearcher = .shared,
        usage: CommandUsageStore = .shared,
        searchIndex: SearchIndex? = nil
    ) {
        self.registry = registry
        self.appLauncher = appLauncher
        self.fileSearcher = fileSearcher
        self.usage = usage
        self.searchIndex = searchIndex
    }

    /// 综合搜索。前缀特殊语法：
    /// `> xxx` 仅搜命令/动作；`app xxx` 仅搜应用；`文件名` 走文件索引；默认混合。
    public func search(query: String) async -> [ScoredCommand] {
        await usage.loadIfNeeded()

        // 特殊前缀
        if query.hasPrefix(">") {
            let q = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            return await registry.search(query: q, limit: 20)
        }
        if query.hasPrefix("app ") {
            let q = String(query.dropFirst(4))
            let apps = await appLauncher.search(q, limit: 15)
            return apps.map { app in
                ScoredCommand(command: CommandItem(
                    id: "app.\(app.id)",
                    title: app.name,
                    subtitle: "打开应用",
                    kind: .application,
                    icon: "app",
                    payload: app.path), score: 1)
            }
        }

        var results = await registry.search(query: query, limit: 20)

        // 应用结果（默认混入）
        if !query.isEmpty {
            let apps = await appLauncher.search(query, limit: 6)
            for app in apps {
                let item = CommandItem(
                    id: "app.\(app.id)",
                    title: app.name,
                    subtitle: "打开应用",
                    kind: .application,
                    icon: "app",
                    payload: app.path)
                results.append(ScoredCommand(command: item, score: 0.8))
            }
        }

        // 文件结果（仅授权目录）
        if !query.isEmpty {
            let hits = await fileSearcher.search(query, limit: 8)
            for hit in hits {
                let item = CommandItem(
                    id: "file.\(hit.path)",
                    title: hit.name,
                    subtitle: hit.isDirectory ? "打开文件夹" : "打开文件",
                    kind: .file,
                    icon: hit.isDirectory ? "folder" : "doc",
                    payload: hit.path)
                results.append(ScoredCommand(command: item, score: 0.7))
            }
        }

        // 资料库全文检索结果
        if !query.isEmpty, let searchIndex {
            if let entries = try? await searchIndex.search(query, limit: 8) {
                for entry in entries {
                    let item = CommandItem(
                        id: "vault.\(entry.type):\(entry.ref)",
                        title: String(entry.text.prefix(60)),
                        subtitle: "资料 · \(entry.type)",
                        kind: .vaultItem,
                        icon: "doc.text.magnifyingglass",
                        payload: "\(entry.type):\(entry.ref)")
                    results.append(ScoredCommand(command: item, score: 0.6))
                }
            }
        }

        // 空查询：最近使用 + 收藏优先
        if query.isEmpty {
            let recentIDs = await usage.recentCommands()
            let favorites = await usage.favorites()
            var ordered: [ScoredCommand] = []
            for id in recentIDs {
                if let found = results.first(where: { $0.id == id }) {
                    ordered.append(found)
                }
            }
            for id in favorites where !ordered.contains(where: { $0.id == id }) {
                if let found = results.first(where: { $0.id == id }) {
                    ordered.append(found)
                }
            }
            return ordered
        }

        return results
    }

    /// 执行命令并记录使用。
    @MainActor
    public func execute(_ command: CommandItem) async -> CommandExecutionResult {
        let result = command.execute()
        if case .success = result {
            await usage.recordExecution(commandID: command.id, title: command.title)
        }
        return result
    }
}
