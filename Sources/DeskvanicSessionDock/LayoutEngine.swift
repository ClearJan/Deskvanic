import AppKit
import ApplicationServices
import Foundation
import DeskvanicCore

/// SessionDock：工作空间布局引擎。
/// 使用 macOS 公开辅助功能 API（AXUIElement）读取与摆放窗口，
/// 需要用户授权辅助功能权限；未授权时如实提示，绝不静默失败。
///
/// 能力边界（如实声明）：
/// - 只能移动/缩放窗口，无法恢复应用内部未保存状态。
/// - 全屏 Space 中的窗口、部分 Electron 应用可能不受 AX 控制——逐一报告。
public enum LayoutEngine {

    public struct WindowSnapshot: Codable, Hashable, Sendable {
        public let appName: String
        public let bundleID: String?
        public let windowTitle: String
        public let frame: CGRect     // 全局坐标（AppKit 左下原点）
        public let displayID: String
    }

    public struct Workspace: Codable, Sendable {
        public let id: String
        public var name: String
        public var apps: [String]          // 要启动的 bundleID / 路径
        public var urls: [String]          // 要打开的 URL
        public var folders: [String]       // 要打开的文件夹
        public var windows: [WindowSnapshot]
        public var createdAt: Date

        public init(id: String = UUID().uuidString, name: String, apps: [String] = [],
                    urls: [String] = [], folders: [String] = [],
                    windows: [WindowSnapshot] = [], createdAt: Date = Date()) {
            self.id = id
            self.name = name
            self.apps = apps
            self.urls = urls
            self.folders = folders
            self.windows = windows
            self.createdAt = createdAt
        }
    }

    // MARK: - 权限

    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - 窗口读取

    /// 读取当前所有可见的标准层窗口（含应用名与位置）。
    public static func captureWindows() -> [WindowSnapshot] {
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var snapshots: [WindowSnapshot] = []
        var seenKeys = Set<String>()

        for dict in raw {
            guard let ownerPID = dict[kCGWindowOwnerPID as String] as? Int,
                  ownerPID != ownPID,
                  (dict[kCGWindowLayer as String] as? Int ?? -1) == 0,
                  let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard frame.width >= 100, frame.height >= 80 else { continue }
            let appName = dict[kCGWindowOwnerName as String] as? String ?? "未知"
            let title = dict[kCGWindowName as String] as? String ?? ""
            let bundleID = bundleID(forPID: ownerPID)
            let display = displayID(for: frame)
            let key = "\(appName)|\(title)|\(Int(frame.minX)),\(Int(frame.minY))"
            guard seenKeys.insert(key).inserted else { continue }
            snapshots.append(WindowSnapshot(
                appName: appName, bundleID: bundleID, windowTitle: title,
                frame: frame, displayID: display))
        }
        return snapshots
    }

    static func bundleID(forPID pid: Int) -> String? {
        NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
    }

    /// 窗口所在显示器（按面积最大交集）。
    static func displayID(for frame: CGRect) -> String {
        var best = "main"
        var bestArea: CGFloat = 0
        for (index, screen) in NSScreen.screens.enumerated() {
            // CG 坐标（左上原点）与 NSScreen frame（左下原点）转换
            let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
            let screenFrame = CGRect(
                x: screen.frame.minX,
                y: primaryHeight - screen.frame.maxY,
                width: screen.frame.width, height: screen.frame.height)
            let intersection = screenFrame.intersection(frame)
            if !intersection.isEmpty && intersection.width * intersection.height > bestArea {
                bestArea = intersection.width * intersection.height
                best = index == 0 ? "main" : screen.localizedName
            }
        }
        return best
    }

    // MARK: - 窗口摆放（AX）

    /// 把指定应用的窗口摆放到目标位置（CG 屏幕坐标，左上原点，点单位）。
    /// 返回是否成功；失败原因可用于 UI 反馈。
    @discardableResult
    public static func placeWindow(
        appBundleID: String, windowTitle: String?, to cgFrame: CGRect
    ) -> Result<Void, PlacementError> {
        guard hasAccessibilityPermission() else { return .failure(.accessibilityDenied) }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: appBundleID).first else {
            return .failure(.appNotRunning(appBundleID))
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else {
            return .failure(.noWindows(appBundleID))
        }

        // 屏幕坐标（左上原点）→ AX 坐标（AXUsesGlobalCoordinates，左上原点，含菜单栏）。
        // AX 的全局坐标以主屏左上为原点——与 CGWindowList 一致。
        let candidates = windows.filter { window in
            guard let windowTitle, !windowTitle.isEmpty else { return true }
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String ?? ""
            return title == windowTitle || windowTitle.isEmpty
        }
        guard let target = candidates.first ?? windows.first else {
            return .failure(.noWindows(appBundleID))
        }

        // AX 位置与尺寸
        var position = CGPoint(x: cgFrame.minX, y: cgFrame.minY)
        guard let posValue = AXValueCreate(.cgPoint, &position) else {
            return .failure(.axError)
        }
        let setResult = AXUIElementSetAttributeValue(target, kAXPositionAttribute as CFString, posValue)
        guard setResult == .success else {
            return .failure(.axError)
        }
        var size = CGSize(width: cgFrame.width, height: cgFrame.height)
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(target, kAXSizeAttribute as CFString, sizeValue)
        }
        return .success(())
    }

    public enum PlacementError: Error, Sendable {
        case accessibilityDenied
        case appNotRunning(String)
        case noWindows(String)
        case axError
    }

    // MARK: - 应用启动

    public static func launch(apps: [String]) async -> [String] {
        var failures: [String] = []
        for identifier in apps {
            let url: URL?
            if identifier.hasPrefix("/") {
                url = URL(fileURLWithPath: identifier)
            } else if let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: identifier) {
                url = appURL
            } else {
                url = nil
            }
            guard let url else {
                failures.append(identifier)
                continue
            }
            do {
                try await NSWorkspace.shared.openApplication(
                    at: url, configuration: NSWorkspace.OpenConfiguration())
                // 等待窗口出现（最多 3 秒）
                for _ in 0..<6 {
                    if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first?.isActive == true {
                        break
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            } catch {
                failures.append(identifier)
            }
        }
        return failures
    }

    /// 应用分屏预设：把两个应用左右各占一半。
    public static func splitLeftRight(left appA: String, right appB: String, on screen: NSScreen) -> [Result<Void, PlacementError>] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = screen.frame
        let cgY = primaryHeight - frame.maxY
        let halfWidth = frame.width / 2
        let leftResult = placeWindow(
            appBundleID: appA, windowTitle: nil,
            to: CGRect(x: frame.minX, y: cgY, width: halfWidth, height: frame.height))
        let rightResult = placeWindow(
            appBundleID: appB, windowTitle: nil,
            to: CGRect(x: frame.minX + halfWidth, y: cgY, width: halfWidth, height: frame.height))
        return [leftResult, rightResult]
    }
}

/// 工作空间持久化（kv_store JSON）。
public actor WorkspaceStore {
    private let db: Database
    private let key = "sessionDock.workspaces"

    public init(database: Database) {
        self.db = database
    }

    public func load() async -> [LayoutEngine.Workspace] {
        guard let rows = try? await db.run("SELECT value FROM kv_store WHERE key = ?", [.text(key)]),
              let json = rows.first?["value"]?.stringValue,
              let data = json.data(using: .utf8),
              let workspaces = try? JSONDecoder().decode([LayoutEngine.Workspace].self, from: data) else {
            return []
        }
        return workspaces
    }

    public func save(_ workspaces: [LayoutEngine.Workspace]) async {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        _ = try? await db.runUpdate(
            "INSERT INTO kv_store(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(String(data: data, encoding: .utf8) ?? "[]")])
    }
}
