import Foundation
import DeskvanicCore

/// 资料条目类型。
public enum VaultKind: String, Codable, Sendable, CaseIterable {
    case text
    case url
    case image
    case pdf
    case file

    public var displayName: String {
        switch self {
        case .text: return "文本"
        case .url: return "链接"
        case .image: return "图片"
        case .pdf: return "PDF"
        case .file: return "文件"
        }
    }
}

/// 存储模式：复制进库 vs 引用原始路径。
public enum VaultStorageMode: String, Codable, Sendable {
    case copied      // 文件复制进 VaultStorage，库内自持
    case referenced  // 仅记录原始路径，文件留在原地
}

/// 资料条目。
public struct VaultItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let kind: VaultKind
    public var title: String
    public var contentText: String?      // 文本/链接内容；文件时为备注
    /// 复制进库的文件路径（VaultStorage 下）。
    public let storagePath: String?
    /// 引用模式的原始路径。
    public let referencePath: String?
    public let storageMode: VaultStorageMode?
    public var sourceApp: String?
    public var favorite: Bool
    public var tags: [String]
    public var ocrText: String?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: VaultKind,
        title: String,
        contentText: String? = nil,
        storagePath: String? = nil,
        referencePath: String? = nil,
        storageMode: VaultStorageMode? = nil,
        sourceApp: String? = nil,
        favorite: Bool = false,
        tags: [String] = [],
        ocrText: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.contentText = contentText
        self.storagePath = storagePath
        self.referencePath = referencePath
        self.storageMode = storageMode
        self.sourceApp = sourceApp
        self.favorite = favorite
        self.tags = tags
        self.ocrText = ocrText
        self.createdAt = createdAt
    }

    /// 条目对应的实际文件（若有）。
    public var effectiveFilePath: String? {
        storagePath ?? referencePath
    }

    /// 文件可用性：复制模式看 storagePath；引用模式看原文件是否仍在。
    public var fileStatus: VaultFileStatus {
        guard let path = effectiveFilePath else { return .notApplicable }
        if FileManager.default.fileExists(atPath: path) { return .available }
        return storageMode == .referenced ? .missing : .missing
    }
}

public enum VaultFileStatus: String, Sendable {
    case available
    case missing
    case notApplicable
}

/// 资料库存储（SQLite + FTS + 标签表）。
public actor VaultStore {
    private let db: Database
    private let index: SearchIndex

    public init(database: Database, index: SearchIndex) {
        self.db = database
        self.index = index
    }

    // MARK: - 读取

    public struct Filter: Sendable {
        public var query: String = ""
        public var kind: VaultKind?
        public var tag: String?
        public var favoriteOnly: Bool = false
        public var limit: Int = 500

        public init(query: String = "", kind: VaultKind? = nil, tag: String? = nil,
                    favoriteOnly: Bool = false, limit: Int = 500) {
            self.query = query
            self.kind = kind
            self.tag = tag
            self.favoriteOnly = favoriteOnly
            self.limit = limit
        }
    }

    public func items(filter: Filter = Filter()) async throws -> [VaultItem] {
        var conditions: [String] = []
        var params: [SQLiteValue] = []

        if let kind = filter.kind {
            conditions.append("v.kind = ?")
            params.append(.text(kind.rawValue))
        }
        if filter.favoriteOnly {
            conditions.append("v.favorite = 1")
        }
        if let tag = filter.tag {
            conditions.append("EXISTS(SELECT 1 FROM vault_tags t WHERE t.item_id = v.id AND t.tag = ?)")
            params.append(.text(tag))
        }
        let conditionClause = conditions.isEmpty ? "" : " AND " + conditions.joined(separator: " AND ")
        let select = """
            SELECT v.id, v.kind, v.title, v.content_text, v.storage_path, v.reference_path,
                   v.storage_mode, v.source_app, v.favorite, v.ocr_text, v.created_at
            FROM vault_items v
            """

        var results: [VaultItem] = []

        // 全文检索优先（FTS），无命中时退化 LIKE
        if !filter.query.isEmpty {
            let ftsHits = ((try? await index.search(filter.query, limit: filter.limit)) ?? [])
                .filter { $0.type == "vault" }
            let ids = Set(ftsHits.map(\.ref))
            if !ids.isEmpty {
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                let rows = try await db.run(
                    select + " WHERE v.id IN (\(placeholders))",
                    ids.map { .text($0) })
                results = rows.compactMap(Self.decode).filter { item in
                    (filter.kind == nil || item.kind == filter.kind)
                        && (!filter.favoriteOnly || item.favorite)
                        && (filter.tag == nil || item.tags.contains(filter.tag!))
                }
            } else {
                let like = "%\(filter.query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_"))%"
                let likeCondition = "(v.title LIKE ? ESCAPE '\\' OR v.content_text LIKE ? ESCAPE '\\' OR v.ocr_text LIKE ? ESCAPE '\\')"
                let sql = select
                    + " WHERE " + likeCondition
                    + conditionClause
                    + " ORDER BY v.favorite DESC, v.created_at DESC LIMIT ?"
                let rows = try await db.run(
                    sql,
                    [.text(like), .text(like), .text(like)] + params + [.int(Int64(filter.limit))])
                results = rows.compactMap(Self.decode)
            }
        } else {
            let sql = select
                + " WHERE 1=1" + conditionClause
                + " ORDER BY v.favorite DESC, v.created_at DESC LIMIT ?"
            let rows = try await db.run(
                sql,
                params + [.int(Int64(filter.limit))])
            results = rows.compactMap(Self.decode)
        }

        return results
    }

    public func item(id: String) async throws -> VaultItem? {
        let rows = try await db.run(
            """
            SELECT v.id, v.kind, v.title, v.content_text, v.storage_path, v.reference_path,
                   v.storage_mode, v.source_app, v.favorite, v.ocr_text, v.created_at
            FROM vault_items v WHERE v.id = ?
            """,
            [.text(id)])
        return rows.first.flatMap(Self.decode)
    }

    public func allTags() async throws -> [String] {
        let rows = try await db.run(
            "SELECT tag, COUNT(*) AS c FROM vault_tags GROUP BY tag ORDER BY c DESC")
        return rows.compactMap { $0["tag"]?.stringValue }
    }

    /// 全部条目的标签映射（刷新列表时一次性加载）。
    public func tagsByItem() async throws -> [String: [String]] {
        let rows = try await db.run("SELECT item_id, tag FROM vault_tags")
        var map: [String: [String]] = [:]
        for row in rows {
            guard let itemID = row["item_id"]?.stringValue,
                  let tag = row["tag"]?.stringValue else { continue }
            map[itemID, default: []].append(tag)
        }
        return map
    }

    // MARK: - 写入

    public func add(_ item: VaultItem) async throws {
        _ = try await db.runUpdate(
            """
            INSERT INTO vault_items(id, kind, title, content_text, storage_path, reference_path,
                                    storage_mode, source_app, favorite, ocr_text, created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """,
            [.text(item.id), .text(item.kind.rawValue), .text(item.title),
             item.contentText.map { .text($0) } ?? .null,
             item.storagePath.map { .text($0) } ?? .null,
             item.referencePath.map { .text($0) } ?? .null,
             item.storageMode.map { .text($0.rawValue) } ?? .null,
             item.sourceApp.map { .text($0) } ?? .null,
             .int(item.favorite ? 1 : 0),
             item.ocrText.map { .text($0) } ?? .null,
             .text(DateCodec.encode(item.createdAt))])
        try await replaceTags(itemID: item.id, tags: item.tags)
        await reindex(item: item)
        await EventBus.shared.publish(EventTopics.vaultItemAdded, ["kind": item.kind.rawValue])
    }

    public func update(_ item: VaultItem) async throws {
        _ = try await db.runUpdate(
            """
            UPDATE vault_items SET title = ?, content_text = ?, favorite = ?, ocr_text = ? WHERE id = ?
            """,
            [.text(item.title), item.contentText.map { .text($0) } ?? .null,
             .int(item.favorite ? 1 : 0),
             item.ocrText.map { .text($0) } ?? .null, .text(item.id)])
        try await replaceTags(itemID: item.id, tags: item.tags)
        await reindex(item: item)
    }

    public func setFavorite(id: String, favorite: Bool) async throws {
        _ = try await db.runUpdate("UPDATE vault_items SET favorite = ? WHERE id = ?",
                                   [.int(favorite ? 1 : 0), .text(id)])
    }

    public func delete(id: String, removeStoredFiles: Bool = true) async throws {
        let item = try await item(id: id)
        _ = try await db.runUpdate("DELETE FROM vault_items WHERE id = ?", [.text(id)])
        _ = try await db.runUpdate("DELETE FROM vault_tags WHERE item_id = ?", [.text(id)])
        try await index.remove(type: "vault", ref: id)
        if removeStoredFiles, let path = item?.storagePath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    public func replaceTags(itemID: String, tags: [String]) async throws {
        _ = try await db.runUpdate("DELETE FROM vault_tags WHERE item_id = ?", [.text(itemID)])
        for tag in Set(tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) {
            _ = try? await db.runUpdate(
                "INSERT OR IGNORE INTO vault_tags(item_id, tag) VALUES(?, ?)",
                [.text(itemID), .text(tag)])
        }
    }

    /// 更新 FTS 索引（标题 + 内容 + OCR）。
    public func reindex(item: VaultItem) async {
        let text = [item.title, item.contentText ?? "", item.ocrText ?? "",
                    item.tags.joined(separator: " ")]
            .joined(separator: "\n")
        try? await index.upsert(type: "vault", ref: item.id, text: text)
    }

    /// 重建全部索引（损坏恢复路径）。
    public func rebuildIndex() async throws {
        try await index.rebuild()
        let rows = try await db.run(
            """
            SELECT v.id, v.kind, v.title, v.content_text, v.storage_path, v.reference_path,
                   v.storage_mode, v.source_app, v.favorite, v.ocr_text, v.created_at
            FROM vault_items v
            """)
        for item in rows.compactMap(Self.decode) {
            await reindex(item: item)
        }
        Log.info("资料库索引已重建", category: .vault)
    }

    // MARK: - 内部

    static func decode(_ row: DatabaseRow) -> VaultItem? {
        guard let id = row["id"]?.stringValue,
              let kindRaw = row["kind"]?.stringValue,
              let kind = VaultKind(rawValue: kindRaw),
              let title = row["title"]?.stringValue else { return nil }
        let storageModeRaw = row["storage_mode"]?.stringValue
        return VaultItem(
            id: id, kind: kind, title: title,
            contentText: row["content_text"]?.stringValue,
            storagePath: row["storage_path"]?.stringValue,
            referencePath: row["reference_path"]?.stringValue,
            storageMode: storageModeRaw.flatMap(VaultStorageMode.init(rawValue:)),
            sourceApp: row["source_app"]?.stringValue,
            favorite: (row["favorite"]?.int64Value ?? 0) == 1,
            tags: [],  // 标签由调用方按需加载
            ocrText: row["ocr_text"]?.stringValue,
            createdAt: DateCodec.decode(row["created_at"]?.stringValue ?? "") ?? Date())
    }
}

/// Vault 数据库迁移（版本 5）。
public enum VaultSchema {
    public static let migration = DBMigration(version: 5, name: "recall-vault", statements: [
        """
        CREATE TABLE vault_items(
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            content_text TEXT,
            storage_path TEXT,
            reference_path TEXT,
            storage_mode TEXT,
            source_app TEXT,
            favorite INTEGER NOT NULL DEFAULT 0,
            ocr_text TEXT,
            created_at TEXT NOT NULL
        )
        """,
        "CREATE INDEX idx_vault_created ON vault_items(created_at DESC)",
        "CREATE INDEX idx_vault_kind ON vault_items(kind)",
        """
        CREATE TABLE vault_tags(
            item_id TEXT NOT NULL,
            tag TEXT NOT NULL,
            PRIMARY KEY(item_id, tag)
        )
        """,
        "CREATE INDEX idx_vault_tags_tag ON vault_tags(tag)",
    ])
}
