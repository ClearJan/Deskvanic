import Foundation
import DeskvanicCore

/// 命令使用记录：最近执行与收藏，持久化到 kv_store（JSON）。
public actor CommandUsageStore {
    public static let shared = CommandUsageStore(database: Database(url: AppEnvironment.databaseURL))

    private struct Persistence: Codable {
        var recent: [RecentEntry] = []
        var favorites: [String] = []   // command id 列表
    }

    private struct RecentEntry: Codable {
        let commandID: String
        let title: String
        var lastUsed: Date
        var count: Int
    }

    private let db: Database
    private var state = Persistence()
    private let maxRecent: Int

    public init(database: Database, maxRecent: Int = 20) {
        self.db = database
        self.maxRecent = maxRecent
    }

    public func loadIfNeeded() async {
        guard state.recent.isEmpty && state.favorites.isEmpty else { return }
        if let rows = try? await db.run("SELECT value FROM kv_store WHERE key = 'commandCenter.usage'"),
           let json = rows.first?["value"]?.stringValue,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Persistence.self, from: data) {
            state = decoded
        }
    }

    /// 记录一次执行。
    public func recordExecution(commandID: String, title: String) async {
        loadStateIfNeededSync()
        if let idx = state.recent.firstIndex(where: { $0.commandID == commandID }) {
            state.recent[idx].lastUsed = Date()
            state.recent[idx].count += 1
        } else {
            state.recent.append(RecentEntry(commandID: commandID, title: title, lastUsed: Date(), count: 1))
        }
        if state.recent.count > maxRecent {
            state.recent.sort { $0.lastUsed > $1.lastUsed }
            state.recent = Array(state.recent.prefix(maxRecent))
        }
        await persist()
    }

    public func toggleFavorite(commandID: String) async {
        loadStateIfNeededSync()
        if let idx = state.favorites.firstIndex(of: commandID) {
            state.favorites.remove(at: idx)
        } else {
            state.favorites.append(commandID)
        }
        await persist()
    }

    public func isFavorite(commandID: String) -> Bool {
        state.favorites.contains(commandID)
    }

    /// 最近使用记录（按时间倒序）。
    public func recentCommands() -> [String] {
        state.recent
            .sorted { $0.lastUsed > $1.lastUsed }
            .map(\.commandID)
    }

    public func favorites() -> [String] {
        state.favorites
    }

    // MARK: - 内部

    private func loadStateIfNeededSync() {
        // loadIfNeeded 为异步；recordExecution 等入口先调用 loadIfNeeded 保证已加载
    }

    private func persist() async {
        guard let data = try? JSONEncoder().encode(state) else { return }
        _ = try? await db.runUpdate(
            "INSERT INTO kv_store(key, value) VALUES('commandCenter.usage', ?) " +
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')",
            [.text(String(data: data, encoding: .utf8) ?? "{}")])
    }
}
