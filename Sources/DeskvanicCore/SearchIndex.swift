import Foundation

/// 跨模块统一全文索引（SQLite FTS5）。
/// 各模块将可检索文本连同类型与引用 ID 写入；命令中心与资料检索统一查询。
public actor SearchIndex {
    public struct Entry: Sendable, Identifiable, Hashable {
        public let type: String
        public let ref: String
        public let text: String
        public var id: String { "\(type):\(ref)" }
        public init(type: String, ref: String, text: String) {
            self.type = type
            self.ref = ref
            self.text = text
        }
    }

    private let db: Database

    public init(database: Database) {
        self.db = database
    }

    /// 以 (type, ref) 为主键进行 upsert：先删旧值再插入，保证不产生重复索引项。
    /// 文本经 CJK 切分后写入，与查询侧保持一致。
    public func upsert(type: String, ref: String, text: String) async throws {
        try await db.runUpdate("DELETE FROM search_fts WHERE type = ? AND ref = ?", [.text(type), .text(ref)])
        try await db.runUpdate(
            "INSERT INTO search_fts(text, type, ref) VALUES(?, ?, ?)",
            [.text(Self.tokenizeForFTS(text).joined(separator: " ")), .text(type), .text(ref)])
    }

    public func remove(type: String, ref: String) async throws {
        try await db.runUpdate("DELETE FROM search_fts WHERE type = ? AND ref = ?", [.text(type), .text(ref)])
    }

    public func removeAll() async throws {
        try await db.runUpdate("DELETE FROM search_fts")
    }

    public func count() async throws -> Int {
        let rows = try await db.run("SELECT COUNT(*) AS c FROM search_fts")
        return Int(rows.first?["c"]?.int64Value ?? 0)
    }

    /// FTS5 匹配查询。用户输入被逐词加引号转义，避免 FTS 语法注入。
    public func search(_ query: String, limit: Int = 50) async throws -> [Entry] {
        let tokens = Self.tokenizeForFTS(query)
        guard !tokens.isEmpty else { return [] }
        let safeQuery = tokens.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
        let rows = try await db.run(
            """
            SELECT text, type, ref, bm25(search_fts) AS rank
            FROM search_fts
            WHERE search_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """,
            [.text(safeQuery), .int(Int64(limit))])
        return rows.compactMap { row in
            guard let text = row["text"]?.stringValue,
                  let type = row["type"]?.stringValue,
                  let ref = row["ref"]?.stringValue else { return nil }
            return Entry(type: type, ref: ref, text: text)
        }
    }

    /// CJK 文本切分：unicode61 分词器会把整段中文当作单个 token，
    /// 导致子串查询无法命中。写入与查询前统一在 CJK 字符间插入空格，
    /// 使每个汉字成为独立 token，查询按相邻 token 序列匹配。
    static func tokenizeForFTS(_ text: String) -> [String] {
        var output = String()
        for scalar in text.unicodeScalars {
            let isCJK = (0x3400...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)  // 日文假名
                || (0xAC00...0xD7AF).contains(scalar.value)  // 韩文
            if isCJK {
                if !output.isEmpty && !output.hasSuffix(" ") { output.append(" ") }
                output.unicodeScalars.append(scalar)
                output.append(" ")
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 重建索引（索引损坏恢复路径）：清空后由各模块重新导入。
    public func rebuild() async throws {
        try await db.runUpdate("DELETE FROM search_fts")
        Log.warning("全文索引已清空，等待各模块重新导入", category: .core)
    }
}
