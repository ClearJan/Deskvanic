import Foundation
import DeskvanicCore

/// 命令注册表：各模块在启动时注册自己的命令；命令中心汇总搜索。
public actor CommandRegistry {
    public static let shared = CommandRegistry()

    private var commands: [CommandItem] = []
    private var providers: [String: @Sendable (String) async -> [CommandItem]] = [:]

    /// 注册静态命令。ID 重复时后者覆盖前者（便于模块重载自己的命令）。
    public func register(_ command: CommandItem) {
        commands.removeAll { $0.id == command.id }
        commands.append(command)
    }

    public func register(_ items: [CommandItem]) {
        for item in items { register(item) }
    }

    /// 注册动态提供者：面板搜索时按需生成候选（例如剪贴板历史、资料条目）。
    /// providerID 用于去重与替换。
    public func registerProvider(id: String, provider: @escaping @Sendable (String) async -> [CommandItem]) {
        providers[id] = provider
    }

    public func removeProvider(id: String) {
        providers[id] = nil
    }

    public var staticCommands: [CommandItem] { commands }

    /// 汇总静态命令与各 provider 结果并按模糊匹配排序。
    /// 空查询时只返回静态命令（provider 跳过，避免无输入时的昂贵查询）。
    public func search(query: String, limit: Int = 30) async -> [ScoredCommand] {
        var candidates = commands
        if !query.isEmpty {
            for provider in providers.values {
                let items = await provider(query)
                candidates.append(contentsOf: items)
            }
        }
        let ranked = FuzzyMatcher.rank(candidates, query: query) { item in
            "\(item.title) \(item.subtitle ?? "")"
        }
        return Array(ranked.prefix(limit)).map { ScoredCommand(command: $0.item, score: $0.score) }
    }
}
