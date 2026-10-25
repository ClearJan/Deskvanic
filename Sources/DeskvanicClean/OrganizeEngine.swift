import Foundation
import DeskvanicCore

/// 整理规则引擎：按扩展名分类 → 生成移动计划 → 模拟运行 → 冲突报告 → 确认执行。
/// 安全原则：只移动不删除；同卷 rename、跨卷 copy+废纸篓；冲突时生成不覆盖名称或拒绝；
/// 每次执行记录审计；已整理文件登记防重复触发。
public enum OrganizeEngine {

    public struct Rule: Codable, Sendable {
        public var name: String
        /// 扩展名（小写、不含点）→ 目标子文件夹名。
        public var mapping: [String: String]
        /// 扫描子文件夹（如"文档/发票"）也算命中。
        public var includeSubfolders: [String]

        public init(name: String, mapping: [String: String], includeSubfolders: [String] = []) {
            self.name = name
            self.mapping = mapping
            self.includeSubfolders = includeSubfolders
        }

        /// 下载目录默认规则。
        public static func downloadsDefault() -> Rule {
            Rule(
                name: "下载目录整理",
                mapping: [
                    // 图片
                    "png": "图片", "jpg": "图片", "jpeg": "图片", "heic": "图片",
                    "gif": "图片", "webp": "图片", "tiff": "图片",
                    // 文档
                    "pdf": "文档", "doc": "文档", "docx": "文档", "xls": "文档", "xlsx": "文档",
                    "ppt": "文档", "pptx": "文档", "txt": "文档", "md": "文档", "pages": "文档",
                    "numbers": "文档", "key": "文档", "csv": "文档",
                    // 音视频
                    "mp3": "音频", "wav": "音频", "aac": "音频", "m4a": "音频", "flac": "音频",
                    "mp4": "视频", "mov": "视频", "mkv": "视频", "avi": "视频",
                    // 压缩包与安装包
                    "zip": "压缩包", "rar": "压缩包", "7z": "压缩包", "tar": "压缩包", "gz": "压缩包",
                    "dmg": "安装包", "pkg": "安装包",
                ],
                includeSubfolders: [])
        }
    }

    public struct PlannedMove: Identifiable, Sendable {
        public let id: String
        public let source: String
        public let target: String
        public let category: String
        public let sizeBytes: Int64
        /// 冲突：目标已存在同名文件（内容不同）。执行时将改名而不是覆盖。
        public let conflict: Bool
    }

    public struct Plan: Sendable {
        public let moves: [PlannedMove]
        public let skipped: [(path: String, reason: String)]
        public var totalBytes: Int64 { moves.reduce(0) { $0 + $1.sizeBytes } }
        public var conflicts: [PlannedMove] { moves.filter(\.conflict) }
    }

    public static func category(for fileName: String, rule: Rule) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return rule.mapping[ext]
    }

    /// 生成模拟运行计划（不执行任何 IO 写操作；只读检查）。
    public static func plan(
        files: [String], in root: String, rule: Rule,
        alreadyOrganized: Set<String>
    ) -> Plan {
        var moves: [PlannedMove] = []
        var skipped: [(String, String)] = []
        let fm = FileManager.default

        for path in files {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            // 防重复触发：已整理过的文件跳过
            if alreadyOrganized.contains(path) {
                skipped.append((path, "上次整理已移动过此文件"))
                continue
            }
            // 文件仍存在？
            guard fm.fileExists(atPath: path) else {
                skipped.append((path, "文件不存在"))
                continue
            }
            // 只处理规则根目录内的文件（含子文件夹扫描范围）
            guard FileSafety.isContained(url, in: URL(fileURLWithPath: root)) else {
                skipped.append((path, "超出授权目录范围"))
                continue
            }
            // 隐藏文件与 .app 不动
            if name.hasPrefix(".") {
                skipped.append((path, "隐藏文件"))
                continue
            }
            guard let category = category(for: name, rule: rule) else {
                skipped.append((path, "无匹配分类规则"))
                continue
            }
            // 已在目标分类目录内的不再移动
            let parentName = url.deletingLastPathComponent().lastPathComponent
            if parentName == category {
                skipped.append((path, "已位于分类目录"))
                continue
            }

            let targetDir = URL(fileURLWithPath: root).appendingPathComponent(category, isDirectory: true)
            let target = targetDir.appendingPathComponent(name)
            let conflict = fm.fileExists(atPath: target.path)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            moves.append(PlannedMove(
                id: UUID().uuidString, source: path, target: target.path,
                category: category, sizeBytes: size, conflict: conflict))
        }
        return Plan(moves: moves, skipped: skipped)
    }

    // MARK: - 执行

    public struct ExecutionResult: Sendable {
        public let movedCount: Int
        public let failedCount: Int
        public let failures: [(source: String, reason: String)]
    }

    /// 执行计划：同卷 rename；跨卷 copy + 原文件进废纸篓（可恢复）。
    /// 目标同名冲突时使用 "name 2.ext"（不覆盖）。每步记录。
    @MainActor
    public static func execute(
        _ plan: Plan, in root: String, audit: AuditLog
    ) async -> ExecutionResult {
        let fm = FileManager.default
        var moved = 0
        var failures: [(String, String)] = []

        // 先建目标分类目录
        let categories = Set(plan.moves.map(\.category))
        for category in categories {
            let dir = URL(fileURLWithPath: root).appendingPathComponent(category, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        for move in plan.moves {
            let sourceURL = URL(fileURLWithPath: move.source)
            let targetDir = URL(fileURLWithPath: move.target).deletingLastPathComponent()
            do {
                let finalTarget = FileSafety.uniqueDestination(
                    in: targetDir, preferredName: sourceURL.lastPathComponent)
                if FileSafety.isSameVolume(sourceURL, finalTarget) {
                    try fm.moveItem(at: sourceURL, to: finalTarget)
                } else {
                    try fm.copyItem(at: sourceURL, to: finalTarget)
                    try await FileSafety.validateOutput(at: finalTarget, expectedMinBytes: 1)
                    _ = try await FileSafety.moveToTrash(sourceURL)
                }
                moved += 1
                await audit.record(
                    action: "clean.move",
                    subject: move.source,
                    outcome: "ok",
                    detail: "→ \(finalTarget.path)")
            } catch {
                failures.append((move.source, String(describing: error)))
                await audit.record(
                    action: "clean.move", subject: move.source,
                    outcome: "failed", detail: String(describing: error))
            }
        }
        return ExecutionResult(movedCount: moved, failedCount: failures.count, failures: failures)
    }
}

/// 整理历史与防重复触发登记（数据库 v6）。
public actor OrganizeHistoryStore {
    private let db: Database

    public init(database: Database) {
        self.db = database
    }

    /// 登记已整理文件（原路径 → 新路径）。
    public func recordOrganized(originalPath: String, newPath: String, root: String) async throws {
        _ = try await db.runUpdate(
            "INSERT OR REPLACE INTO organized_files(original_path, new_path, root, organized_at) VALUES(?,?,?,?)",
            [.text(originalPath), .text(newPath), .text(root), .text(DateCodec.encode(Date()))])
    }

    public func organizedPaths(root: String) async throws -> Set<String> {
        let rows = try await db.run(
            "SELECT original_path FROM organized_files WHERE root = ?", [.text(root)])
        return Set(rows.compactMap { $0["original_path"]?.stringValue })
    }

    public struct OperationRecord: Identifiable, Sendable {
        public let id: Int64
        public let ts: String
        public let action: String
        public let subject: String?
        public let outcome: String
        public let detail: String?
    }

    /// 操作记录（读审计日志中本模块的记录）。
    public func recentOperations(limit: Int = 100) async throws -> [OperationRecord] {
        let rows = try await db.run(
            "SELECT id, ts, action, subject, outcome, detail FROM audit_log WHERE action LIKE 'clean.%' ORDER BY id DESC LIMIT ?",
            [.int(Int64(limit))])
        return rows.compactMap { row in
            guard let id = row["id"]?.int64Value,
                  let ts = row["ts"]?.stringValue,
                  let action = row["action"]?.stringValue,
                  let outcome = row["outcome"]?.stringValue else { return nil }
            return OperationRecord(
                id: id, ts: ts, action: action, subject: row["subject"]?.stringValue,
                outcome: outcome, detail: row["detail"]?.stringValue)
        }
    }
}

/// Clean Manager 数据库迁移（版本 6）。
public enum CleanSchema {
    public static let migration = DBMigration(version: 6, name: "clean-manager", statements: [
        """
        CREATE TABLE organized_files(
            original_path TEXT NOT NULL,
            new_path TEXT NOT NULL,
            root TEXT NOT NULL,
            organized_at TEXT NOT NULL,
            PRIMARY KEY(original_path, root)
        )
        """,
        "CREATE INDEX idx_organized_root ON organized_files(root)",
    ])
}
