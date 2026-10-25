import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteValue: Sendable, Equatable {
    case text(String)
    case int(Int64)
    case real(Double)
    case blob(Data)
    case null

    public var stringValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }
    public var int64Value: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }
    public var doubleValue: Double? {
        switch self {
        case .real(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public var blobValue: Data? {
        if case .blob(let b) = self { return b }
        return nil
    }
}

public struct DatabaseRow: Sendable {
    public let columns: [String: SQLiteValue]
    public subscript(_ key: String) -> SQLiteValue? { columns[key] }
    public var firstStringValue: String? { columns.values.compactMap(\.stringValue).first }
}

/// 单个迁移步骤：版本号 + 一组按顺序执行的 SQL（整体在一个事务中提交）。
public struct DBMigration: Sendable {
    public let version: Int
    public let name: String
    public let statements: [String]
    public init(version: Int, name: String, statements: [String]) {
        self.version = version
        self.name = name
        self.statements = statements
    }
}

/// SQLite 封装：actor 隔离保证单线程访问，WAL 模式，带版本化迁移、备份与完整性检查。
/// 连接句柄与全部 sqlite3 C 调用都封闭在 actor 内部，满足 Swift 6 严格并发检查。
public actor Database {
    private var handle: OpaquePointer?
    public let path: String
    private var opened = false

    public init(url: URL) {
        self.path = url.path
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    // 说明：本工具链的 actor deinit 不允许访问非 Sendable 成员（isolated deinit 未开放），
    // 因此连接必须由调用方通过 close() 显式关闭；未关闭的连接在进程退出时由系统回收，
    // WAL 模式保证崩溃/未关闭场景下的数据一致性。

    public enum DBError: Error, CustomStringConvertible {
        case openFailed(String)
        case prepareFailed(String, sql: String)
        case stepFailed(String, sql: String)
        case bindFailed(String)
        case migrationFailed(version: Int, underlying: String)
        case backupFailed(String)

        public var description: String {
            switch self {
            case .openFailed(let m): return "数据库打开失败: \(m)"
            case .prepareFailed(let m, let sql): return "SQL 预处理失败: \(m) [\(sql.prefix(120))]"
            case .stepFailed(let m, let sql): return "SQL 执行失败: \(m) [\(sql.prefix(120))]"
            case .bindFailed(let m): return "参数绑定失败: \(m)"
            case .migrationFailed(let v, let u): return "迁移 v\(v) 失败: \(u)"
            case .backupFailed(let m): return "备份失败: \(m)"
            }
        }
    }

    public func open() throws {
        guard !opened else { return }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close_v2(db) }
            throw DBError.openFailed(message)
        }
        handle = db
        opened = true
        try rawExec("PRAGMA journal_mode=WAL")
        try rawExec("PRAGMA foreign_keys=ON")
        try rawExec("PRAGMA busy_timeout=5000")
    }

    public func close() {
        guard let db = handle else { return }
        sqlite3_close_v2(db)
        handle = nil
        opened = false
    }

    /// 无结果的 SQL 执行（DDL、PRAGMA 等）。
    public func execute(_ sql: String) throws {
        try ensureOpen()
        try rawExec(sql)
    }

    /// 参数化查询，返回所有行。
    public func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> [DatabaseRow] {
        try ensureOpen()
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [DatabaseRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append(readRow(stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DBError.stepFailed(String(cString: sqlite3_errmsg(handle)), sql: sql)
            }
        }
        return rows
    }

    /// 返回受影响行数（UPDATE/DELETE）。
    public func runUpdate(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        try ensureOpen()
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.stepFailed(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        return Int(sqlite3_changes(handle))
    }

    // MARK: - 迁移

    /// 依次应用尚未执行的迁移；每个迁移在独立事务中提交，失败即中止且不留下半 applied 状态。
    public func migrate(_ migrations: [DBMigration]) throws {
        try ensureOpen()
        try rawExec("""
        CREATE TABLE IF NOT EXISTS schema_migrations(
            version INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            applied_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
        """)
        let applied = try currentVersions()
        for migration in migrations.sorted(by: { $0.version < $1.version }) {
            guard !applied.contains(migration.version) else { continue }
            do {
                try rawExec("BEGIN IMMEDIATE")
                for statement in migration.statements { try rawExec(statement) }
                _ = try run(
                    "INSERT INTO schema_migrations(version, name) VALUES(?, ?)",
                    [.int(Int64(migration.version)), .text(migration.name)])
                try rawExec("COMMIT")
                Log.info("数据库迁移 v\(migration.version)（\(migration.name)）已应用", category: .core)
            } catch {
                try? rawExec("ROLLBACK")
                throw DBError.migrationFailed(version: migration.version, underlying: String(describing: error))
            }
        }
    }

    public func currentVersions() throws -> Set<Int> {
        let rows = try run("SELECT version FROM schema_migrations")
        return Set(rows.compactMap { $0["version"]?.int64Value.map(Int.init) })
    }

    // MARK: - 备份与完整性

    /// 使用 VACUUM INTO 生成一致性快照备份，同时优化文件体积。
    public func backup(to destination: URL) throws {
        try ensureOpen()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(handle, "VACUUM INTO '\(escaped)'", nil, nil, nil) == SQLITE_OK else {
            throw DBError.backupFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    public func integrityCheck() throws -> Bool {
        let rows = try run("PRAGMA integrity_check")
        return rows.first?.firstStringValue == "ok"
    }

    // MARK: - 内部

    private func ensureOpen() throws {
        if !opened { try open() }
        guard handle != nil else { throw DBError.openFailed("handle 不可用") }
    }

    private func rawExec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DBError.stepFailed(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
    }

    private func prepare(_ sql: String, _ params: [SQLiteValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        do {
            for (offset, param) in params.enumerated() {
                let idx = Int32(offset + 1)
                let rc: Int32
                switch param {
                case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
                case .int(let i): rc = sqlite3_bind_int64(stmt, idx, i)
                case .real(let d): rc = sqlite3_bind_double(stmt, idx, d)
                case .blob(let b):
                    b.withUnsafeBytes { raw in
                        _ = sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(b.count), SQLITE_TRANSIENT)
                    }
                    rc = SQLITE_OK
                case .null: rc = sqlite3_bind_null(stmt, idx)
                }
                guard rc == SQLITE_OK else {
                    throw DBError.bindFailed("参数 \(offset + 1) 绑定失败")
                }
            }
            return stmt
        } catch {
            sqlite3_finalize(stmt)
            throw error
        }
    }

    private func readRow(_ stmt: OpaquePointer) -> DatabaseRow {
        var columns: [String: SQLiteValue] = [:]
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_TEXT:
                columns[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
            case SQLITE_INTEGER:
                columns[name] = .int(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT:
                columns[name] = .real(sqlite3_column_double(stmt, i))
            case SQLITE_BLOB:
                if let bytes = sqlite3_column_blob(stmt, i) {
                    let size = Int(sqlite3_column_bytes(stmt, i))
                    columns[name] = .blob(Data(bytes: bytes, count: size))
                } else {
                    columns[name] = .blob(Data())
                }
            default:
                columns[name] = .null
            }
        }
        return DatabaseRow(columns: columns)
    }
}

/// Deskvanic 主数据库默认迁移集。新增表必须追加新版本，禁止修改历史迁移。
public enum DeskvanicSchema {
    public static let migrations: [DBMigration] = [
        DBMigration(version: 1, name: "core-kv-audit", statements: [
            """
            CREATE TABLE kv_store(
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
            """,
            """
            CREATE TABLE audit_log(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts TEXT NOT NULL DEFAULT (datetime('now')),
                actor TEXT NOT NULL,
                action TEXT NOT NULL,
                subject TEXT,
                outcome TEXT NOT NULL,
                detail TEXT
            )
            """,
            "CREATE INDEX idx_audit_ts ON audit_log(ts)",
        ]),
        DBMigration(version: 2, name: "search-fts", statements: [
            """
            CREATE VIRTUAL TABLE search_fts USING fts5(
                text,
                type UNINDEXED,
                ref UNINDEXED,
                tokenize = 'unicode61'
            )
            """,
        ]),
    ]
}
