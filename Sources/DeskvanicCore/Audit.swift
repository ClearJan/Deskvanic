import Foundation

/// 操作审计日志：跨模块记录"谁在何时对什么做了什么、结果如何"。
/// 整理删除、批量重命名、导出、网络传输等敏感操作必须留痕，供用户回查。
public actor AuditLog {
    private let db: Database

    public init(database: Database) {
        self.db = database
    }

    public init() {
        self.db = Database(url: AppEnvironment.databaseURL)
    }

    public func record(
        actor: String = "user",
        action: String,
        subject: String? = nil,
        outcome: String = "ok",
        detail: String? = nil
    ) async {
        do {
            _ = try await db.runUpdate(
                "INSERT INTO audit_log(actor, action, subject, outcome, detail) VALUES(?, ?, ?, ?, ?)",
                [.text(actor), .text(action), subject.map { .text($0) } ?? .null, .text(outcome), detail.map { .text($0) } ?? .null])
        } catch {
            Log.error("审计日志写入失败: \(String(describing: error))", category: .audit)
        }
    }

    public struct Entry: Sendable, Identifiable {
        public let id: Int64
        public let ts: String
        public let actorName: String
        public let action: String
        public let subject: String?
        public let outcome: String
        public let detail: String?
    }

    public func recent(limit: Int = 100) async -> [Entry] {
        guard let rows = try? await db.run(
            "SELECT id, ts, actor, action, subject, outcome, detail FROM audit_log ORDER BY id DESC LIMIT ?",
            [.int(Int64(limit))]) else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"]?.int64Value,
                  let ts = row["ts"]?.stringValue,
                  let actorName = row["actor"]?.stringValue,
                  let action = row["action"]?.stringValue,
                  let outcome = row["outcome"]?.stringValue else { return nil }
            return Entry(
                id: id, ts: ts, actorName: actorName, action: action,
                subject: row["subject"]?.stringValue, outcome: outcome,
                detail: row["detail"]?.stringValue)
        }
    }
}
