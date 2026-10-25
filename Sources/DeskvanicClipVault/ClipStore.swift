import Foundation
import DeskvanicCore

/// 剪贴板历史存储：SQLite 持久化 + FTS 全文索引。
/// 图片等二进制内容落盘到 Captures/Clips，数据库只存路径。
public actor ClipStore {
    private let db: Database
    private let index: SearchIndex
    private let imagesDirectory: URL

    public init(
        database: Database,
        index: SearchIndex,
        imagesDirectory: URL = AppEnvironment.capturesDirectory.appendingPathComponent("Clips", isDirectory: true)
    ) {
        self.db = database
        self.index = index
        self.imagesDirectory = imagesDirectory
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 读取

    public func entries(limit: Int = 500) async throws -> [ClipEntry] {
        let rows = try await db.run(
            """
            SELECT id, kind, content_text, file_path, preview, byte_size,
                   source_app, pinned, favorite, created_at
            FROM clips
            ORDER BY pinned DESC, created_at DESC
            LIMIT ?
            """,
            [.int(Int64(limit))])
        return rows.compactMap(Self.decodeRow)
    }

    public func count() async throws -> Int {
        let rows = try await db.run("SELECT COUNT(*) AS c FROM clips")
        return Int(rows.first?["c"]?.int64Value ?? 0)
    }

    /// 全文搜索（FTS 命中）+ 预览 LIKE 兜底，合并去重。
    public func search(_ query: String, limit: Int = 100) async throws -> [ClipEntry] {
        guard !query.isEmpty else { return try await entries(limit: limit) }
        var resultIDs: [String] = []
        var seen = Set<String>()
        let ftsHits = (try? await index.search(query, limit: limit)) ?? []
        for hit in ftsHits where hit.type == "clip" {
            if seen.insert(hit.ref).inserted { resultIDs.append(hit.ref) }
        }
        let like = "%\(query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_"))%"
        let rows = try await db.run(
            """
            SELECT id, kind, content_text, file_path, preview, byte_size,
                   source_app, pinned, favorite, created_at
            FROM clips
            WHERE preview LIKE ? ESCAPE '\\' OR content_text LIKE ? ESCAPE '\\'
            ORDER BY created_at DESC LIMIT ?
            """,
            [.text(like), .text(like), .int(Int64(limit))])
        for row in rows.compactMap(Self.decodeRow) where seen.insert(row.id).inserted {
            resultIDs.append(row.id)
        }
        guard !resultIDs.isEmpty else { return [] }
        let placeholders = resultIDs.map { _ in "?" }.joined(separator: ",")
        let params: [SQLiteValue] = resultIDs.map { .text($0) }
        let detail = try await db.run(
            """
            SELECT id, kind, content_text, file_path, preview, byte_size,
                   source_app, pinned, favorite, created_at
            FROM clips WHERE id IN (\(placeholders))
            """,
            params)
        let byID = Dictionary(
            detail.compactMap(Self.decodeRow).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return resultIDs.compactMap { byID[$0] }
    }

    // MARK: - 写入

    /// 新增条目。若与最新一条（未固定）内容相同则视为重复：刷新时间而不新增。
    /// 返回（条目, 是否新增）。
    @discardableResult
    public func insert(_ entry: ClipEntry) async throws -> (ClipEntry, Bool) {
        let latest = try await latestEntry()
        if let latest, !latest.pinned, Self.isDuplicate(latest, entry) {
            _ = try await db.runUpdate(
                "UPDATE clips SET created_at = ? WHERE id = ?",
                [.text(Self.iso8601(entry.createdAt)), .text(latest.id)])
            return (latest, false)
        }
        _ = try await db.runUpdate(
            """
            INSERT INTO clips(id, kind, content_text, file_path, preview, byte_size,
                              source_app, pinned, favorite, created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(entry.id), .text(entry.kind.rawValue),
                entry.contentText.map { .text($0) } ?? .null,
                entry.filePath.map { .text($0) } ?? .null,
                .text(entry.preview), .int(Int64(entry.byteSize)),
                entry.sourceApp.map { .text($0) } ?? .null,
                .int(entry.pinned ? 1 : 0), .int(entry.favorite ? 1 : 0),
                .text(Self.iso8601(entry.createdAt)),
            ])
        try await index.upsert(
            type: "clip", ref: entry.id,
            text: [entry.preview, entry.contentText ?? ""].joined(separator: "\n"))
        await EventBus.shared.publish(EventTopics.clipCaptured, ["kind": entry.kind.rawValue])
        return (entry, true)
    }

    public func setPinned(id: String, pinned: Bool) async throws {
        _ = try await db.runUpdate("UPDATE clips SET pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .text(id)])
    }

    public func setFavorite(id: String, favorite: Bool) async throws {
        _ = try await db.runUpdate("UPDATE clips SET favorite = ? WHERE id = ?", [.int(favorite ? 1 : 0), .text(id)])
    }

    /// 删除单条；图片文件一并清理。
    public func delete(id: String) async throws {
        let entry = try await entry(id: id)
        _ = try await db.runUpdate("DELETE FROM clips WHERE id = ?", [.text(id)])
        try await index.remove(type: "clip", ref: id)
        if let path = entry?.filePath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// 批量删除（清理策略执行结果）。
    public func delete(ids: Set<String>) async throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            try await delete(id: id)
        }
    }

    /// 清空全部历史（含图片文件）。固定/收藏条目除非 clearProtected 否则保留。
    public func deleteAll(clearProtected: Bool) async throws {
        let protectedClause = clearProtected ? "" : "WHERE pinned = 0 AND favorite = 0"
        let rows = try await db.run("SELECT id, file_path FROM clips \(protectedClause)")
        for row in rows {
            if let id = row["id"]?.stringValue {
                try await index.remove(type: "clip", ref: id)
            }
            if let path = row["file_path"]?.stringValue {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        _ = try await db.runUpdate("DELETE FROM clips \(protectedClause)")
    }

    public func entry(id: String) async throws -> ClipEntry? {
        let rows = try await db.run(
            """
            SELECT id, kind, content_text, file_path, preview, byte_size,
                   source_app, pinned, favorite, created_at
            FROM clips WHERE id = ?
            """,
            [.text(id)])
        return rows.first.flatMap(Self.decodeRow)
    }

    public func latestEntry() async throws -> ClipEntry? {
        let rows = try await db.run(
            """
            SELECT id, kind, content_text, file_path, preview, byte_size,
                   source_app, pinned, favorite, created_at
            FROM clips ORDER BY created_at DESC LIMIT 1
            """)
        return rows.first.flatMap(Self.decodeRow)
    }

    // MARK: - 图片落盘

    /// 将图片数据写入专用目录，返回路径。
    public func saveImage(_ data: Data) throws -> URL {
        let url = FileSafety.uniqueDestination(
            in: imagesDirectory, preferredName: "clip-\(Int(Date().timeIntervalSince1970)).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 模板

    public func templates() async throws -> [ClipTemplate] {
        let rows = try await db.run("SELECT id, name, content, created_at FROM clip_templates ORDER BY created_at DESC")
        return rows.compactMap { row in
            guard let id = row["id"]?.stringValue,
                  let name = row["name"]?.stringValue,
                  let content = row["content"]?.stringValue else { return nil }
            return ClipTemplate(
                id: id, name: name, content: content,
                createdAt: Self.date(from: row["created_at"]?.stringValue ?? "") ?? Date())
        }
    }

    public func saveTemplate(name: String, content: String) async throws {
        guard !name.isEmpty, !content.isEmpty else {
            throw DeskvanicError(.invalidInput, "模板名称与内容不能为空")
        }
        _ = try await db.runUpdate(
            "INSERT INTO clip_templates(id, name, content) VALUES(?,?,?)",
            [.text(UUID().uuidString), .text(name), .text(content)])
    }

    public func deleteTemplate(id: String) async throws {
        _ = try await db.runUpdate("DELETE FROM clip_templates WHERE id = ?", [.text(id)])
    }

    // MARK: - 内部

    static func isDuplicate(_ a: ClipEntry, _ b: ClipEntry) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .image:
            return a.filePath == b.filePath
        default:
            return a.contentText == b.contentText
        }
    }

    static func decodeRow(_ row: DatabaseRow) -> ClipEntry? {
        guard let id = row["id"]?.stringValue,
              let kindRaw = row["kind"]?.stringValue,
              let kind = ClipKind(rawValue: kindRaw),
              let createdRaw = row["created_at"]?.stringValue else { return nil }
        return ClipEntry(
            id: id,
            kind: kind,
            contentText: row["content_text"]?.stringValue,
            filePath: row["file_path"]?.stringValue,
            preview: row["preview"]?.stringValue ?? "",
            byteSize: Int(row["byte_size"]?.int64Value ?? 0),
            sourceApp: row["source_app"]?.stringValue,
            pinned: (row["pinned"]?.int64Value ?? 0) == 1,
            favorite: (row["favorite"]?.int64Value ?? 0) == 1,
            createdAt: date(from: createdRaw) ?? Date())
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// ClipVault 所需的数据库迁移（版本 3）。
public enum ClipVaultSchema {
    public static let migration = DBMigration(version: 3, name: "clipvault", statements: [
        """
        CREATE TABLE clips(
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            content_text TEXT,
            file_path TEXT,
            preview TEXT NOT NULL DEFAULT '',
            byte_size INTEGER NOT NULL DEFAULT 0,
            source_app TEXT,
            pinned INTEGER NOT NULL DEFAULT 0,
            favorite INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        )
        """,
        "CREATE INDEX idx_clips_created ON clips(created_at DESC)",
        """
        CREATE TABLE clip_templates(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
        """,
    ])
}
