import Foundation
import DeskvanicCore

/// 传输记录存储（数据库 v7）。
public struct TransferRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let direction: String   // send / receive / receive-text
    public let filename: String
    public let sizeBytes: Int64
    public let peer: String
    public let createdAt: Date
}

public actor NearLinkStore {
    private let db: Database

    public init(database: Database) {
        self.db = database
    }

    public func record(_ direction: String, filename: String, bytes: Int64, peer: String) async {
        _ = try? await db.runUpdate(
            "INSERT INTO transfers(id, direction, filename, size_bytes, peer, created_at) VALUES(?,?,?,?,?,?)",
            [.text(UUID().uuidString), .text(direction), .text(filename),
             .int(bytes), .text(peer), .text(DateCodec.encode(Date()))])
    }

    public func recent(limit: Int = 100) async -> [TransferRecord] {
        let rows = (try? await db.run(
            "SELECT id, direction, filename, size_bytes, peer, created_at FROM transfers ORDER BY created_at DESC LIMIT ?",
            [.int(Int64(limit))])) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.stringValue,
                  let direction = row["direction"]?.stringValue,
                  let filename = row["filename"]?.stringValue else { return nil }
            return TransferRecord(
                id: id, direction: direction, filename: filename,
                sizeBytes: row["size_bytes"]?.int64Value ?? 0,
                peer: row["peer"]?.stringValue ?? "",
                createdAt: DateCodec.decode(row["created_at"]?.stringValue ?? "") ?? Date())
        }
    }
}

/// NearLink 数据库迁移（版本 7）。
public enum NearLinkSchema {
    public static let migration = DBMigration(version: 7, name: "nearlink", statements: [
        """
        CREATE TABLE transfers(
            id TEXT PRIMARY KEY,
            direction TEXT NOT NULL,
            filename TEXT NOT NULL,
            size_bytes INTEGER NOT NULL DEFAULT 0,
            peer TEXT,
            created_at TEXT NOT NULL
        )
        """,
        "CREATE INDEX idx_transfers_created ON transfers(created_at DESC)",
    ])
}
