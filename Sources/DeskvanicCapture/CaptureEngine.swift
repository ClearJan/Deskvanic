import AppKit
import CoreGraphics
import Foundation
import DeskvanicCore

/// 屏幕捕获引擎：全屏 / 指定窗口 / 区域截图。
/// 全部使用系统公开 API（CGWindowList），屏幕录制权限由 Permissions 统一管理。
/// 用户拒绝权限时明确反馈，不静默产出黑图。
public enum CaptureEngine {

    public struct WindowInfo: Identifiable, Hashable, Sendable {
        public let id: CGWindowID
        public let title: String
        public let ownerName: String
        public let frame: CGRect
        public let isOnScreen: Bool
    }

    /// 屏幕录制权限是否可用。
    public static func hasScreenPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 请求屏幕录制权限（弹系统对话框；用户需在系统设置中确认）。
    @discardableResult
    public static func requestScreenPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - 捕获

    /// 全屏截图（主显示器）。返回 nil 表示权限被拒或捕获失败。
    public static func captureFullScreen() -> CGImage? {
        guard hasScreenPermission() else { return nil }
        let displayID = CGMainDisplayID()
        return CGDisplayCreateImage(displayID)
    }

    /// 区域截图。rect 为 AppKit 全局坐标（主屏左下原点，点单位），
    /// 内部转换为 CG 屏幕坐标（主屏左上原点）后用 CGWindowListCreateImage 捕获，
    /// 原生支持多显示器与窗口层叠。
    public static func captureRegion(appKitRect rect: CGRect) -> CGImage? {
        guard hasScreenPermission(), !rect.isEmpty, rect.width >= 1, rect.height >= 1 else { return nil }
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryHeight = primary.frame.height
        let cgRect = CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height)
        return CGWindowListCreateImage(
            cgRect, [.optionOnScreenBelowWindow], kCGNullWindowID, [.bestResolution])
    }

    /// 枚举屏幕上的可见窗口（排除自身与桌面级窗口）。
    public static func listWindows() -> [WindowInfo] {
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return raw.compactMap { dict in
            guard let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = dict[kCGWindowOwnerPID as String] as? Int else { return nil }
            if ownerPID == ownPID { return nil }
            // 跳过无层级的系统托盘窗口
            if (dict[kCGWindowLayer as String] as? Int ?? 0) != 0 { return nil }
            guard let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let frame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard frame.width >= 40, frame.height >= 40 else { return nil }
            let owner = dict[kCGWindowOwnerName as String] as? String ?? "未知应用"
            let title = dict[kCGWindowName as String] as? String ?? ""
            return WindowInfo(id: windowID, title: title, ownerName: owner, frame: frame, isOnScreen: true)
        }
    }

    /// 窗口截图（按窗口 ID，含窗口本身）。
    /// 说明：CGWindowListCreateImage 在 macOS 14 起标记废弃（官方建议 ScreenCaptureKit），
    /// V1 采用该 API 保证行为可预期；迁移到 ScreenCaptureKit 列入后续计划（见 KNOWN_ISSUES）。
    public static func captureWindow(id windowID: CGWindowID) -> CGImage? {
        guard hasScreenPermission() else { return nil }
        return CGWindowListCreateImage(
            .null, [.optionIncludingWindow], windowID, [.bestResolution])
    }

    // MARK: - 保存

    /// CGImage 写入 PNG 文件。
    public static func savePNG(_ image: CGImage, to directory: URL) throws -> URL {
        let url = FileSafety.uniqueDestination(
            in: directory, preferredName: "capture-\(Int(Date().timeIntervalSince1970)).png")
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw DeskvanicError(.fileWriteFailed, "PNG 编码失败")
        }
        try data.write(to: url, options: .atomic)
        try FileSafety.validateOutput(at: url)
        return url
    }
}

/// 捕获历史存储（数据库 v4）。
public struct CaptureRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let filePath: String
    public var ocrText: String?
    public var barcodePayloads: [String]
    public let kind: String       // fullscreen / window / region / imported
    public let createdAt: Date

    public init(id: String = UUID().uuidString, filePath: String, ocrText: String? = nil,
                barcodePayloads: [String] = [], kind: String, createdAt: Date = Date()) {
        self.id = id
        self.filePath = filePath
        self.ocrText = ocrText
        self.barcodePayloads = barcodePayloads
        self.kind = kind
        self.createdAt = createdAt
    }
}

public actor CaptureStore {
    private let db: Database
    private let index: SearchIndex

    public init(database: Database, index: SearchIndex) {
        self.db = database
        self.index = index
    }

    public func add(_ record: CaptureRecord) async throws {
        _ = try await db.runUpdate(
            """
            INSERT INTO captures(id, file_path, ocr_text, barcodes, kind, created_at)
            VALUES(?,?,?,?,?,?)
            """,
            [.text(record.id), .text(record.filePath),
             record.ocrText.map { .text($0) } ?? .null,
             .text(record.barcodePayloads.joined(separator: "\n")),
             .text(record.kind), .text(DateCodec.encode(record.createdAt))])
        if let ocr = record.ocrText, !ocr.isEmpty {
            try await index.upsert(type: "capture", ref: record.id, text: ocr)
        }
        await EventBus.shared.publish(EventTopics.captureSaved, ["id": record.id])
    }

    public func updateOCR(id: String, ocrText: String?, barcodes: [String]) async throws {
        _ = try await db.runUpdate(
            "UPDATE captures SET ocr_text = ?, barcodes = ? WHERE id = ?",
            [ocrText.map { .text($0) } ?? .null,
             .text(barcodes.joined(separator: "\n")), .text(id)])
        if let ocr = ocrText, !ocr.isEmpty {
            try await index.upsert(type: "capture", ref: id, text: ocr)
        }
    }

    public func recent(limit: Int = 200) async throws -> [CaptureRecord] {
        let rows = try await db.run(
            "SELECT id, file_path, ocr_text, barcodes, kind, created_at FROM captures ORDER BY created_at DESC LIMIT ?",
            [.int(Int64(limit))])
        return rows.compactMap { row in
            guard let id = row["id"]?.stringValue,
                  let path = row["file_path"]?.stringValue,
                  let kind = row["kind"]?.stringValue else { return nil }
            return CaptureRecord(
                id: id, filePath: path,
                ocrText: row["ocr_text"]?.stringValue,
                barcodePayloads: (row["barcodes"]?.stringValue ?? "")
                    .split(separator: "\n").map(String.init),
                kind: kind,
                createdAt: DateCodec.decode(row["created_at"]?.stringValue ?? "") ?? Date())
        }
    }

    public func delete(id: String) async throws {
        let rows = try await db.run("SELECT file_path FROM captures WHERE id = ?", [.text(id)])
        if let path = rows.first?["file_path"]?.stringValue {
            try? FileManager.default.removeItem(atPath: path)
        }
        _ = try await db.runUpdate("DELETE FROM captures WHERE id = ?", [.text(id)])
        try await index.remove(type: "capture", ref: id)
    }
}

/// CaptureStudio 数据库迁移（版本 4）。
public enum CaptureSchema {
    public static let migration = DBMigration(version: 4, name: "capture-studio", statements: [
        """
        CREATE TABLE captures(
            id TEXT PRIMARY KEY,
            file_path TEXT NOT NULL,
            ocr_text TEXT,
            barcodes TEXT NOT NULL DEFAULT '',
            kind TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """,
        "CREATE INDEX idx_captures_created ON captures(created_at DESC)",
    ])
}
