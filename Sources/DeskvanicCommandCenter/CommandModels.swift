import AppKit
import Foundation
import DeskvanicCore

/// 命令中心命令模型：所有可被全局面板搜索并执行的条目。
public struct CommandItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable {
        case tool          // 打开 Deskvanic 工具模块
        case action        // Deskvanic 内部动作（截图、录音等）
        case application   // 启动已安装应用
        case file          // 打开文件/文件夹
        case clip          // 粘贴剪贴板历史条目
        case vaultItem     // 打开资料库条目
        case webURL        // 打开 URL
    }

    public let id: String          // 稳定唯一标识，如 "tool.capture" / "app.com.apple.Safari"
    public let title: String
    public let subtitle: String?
    public let kind: Kind
    public let icon: String        // SF Symbol
    public let payload: String     // 执行参数（工具ID / bundleID / 路径 / URL / 记录ID）

    public init(id: String, title: String, subtitle: String? = nil, kind: Kind, icon: String, payload: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.icon = icon
        self.payload = payload
    }

    /// 执行命令。返回是否已处理；具体行为按类型分发。
    @MainActor
    public func execute() -> CommandExecutionResult {
        switch kind {
        case .tool:
            NotificationCenter.default.post(name: .deskvanicOpenTool, object: nil, userInfo: ["tool": payload])
            NSApp.activate(ignoringOtherApps: true)
            return .success
        case .action:
            NotificationCenter.default.post(name: .deskvanicRunAction, object: nil, userInfo: ["action": payload])
            return .success
        case .application:
            return NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: payload),
                configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error {
                        Log.error("启动应用失败 [\(payload)]: \(String(describing: error))", category: .command)
                    }
                } == nil ? .failed(message: "无法发起应用启动") : .success
        case .file:
            let url = URL(fileURLWithPath: payload)
            guard FileManager.default.fileExists(atPath: payload) else {
                return .failed(message: "文件不存在：\(url.lastPathComponent)")
            }
            NSWorkspace.shared.open(url)
            return .success
        case .webURL:
            guard let url = URL(string: payload), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return .failed(message: "无效的链接")
            }
            NSWorkspace.shared.open(url)
            return .success
        case .clip, .vaultItem:
            // 由对应模块订阅 deskvanicRunAction 处理（模块解耦）
            NotificationCenter.default.post(
                name: .deskvanicRunAction,
                object: nil,
                userInfo: ["action": kind == .clip ? "paste-clip" : "open-vault-item", "ref": payload])
            return .success
        }
    }
}

public enum CommandExecutionResult: Sendable {
    case success
    case failed(message: String)
}

extension Notification.Name {
    /// 打开指定工具（payload = 工具 ID）
    public static let deskvanicOpenTool = Notification.Name("deskvanic.openTool")
    /// 执行 Deskvanic 动作（action 键 = 动作名，可带 ref）
    public static let deskvanicRunAction = Notification.Name("deskvanic.runAction")
}

/// 搜索结果条目：命令 + 匹配得分。
public struct ScoredCommand: Identifiable, Hashable, Sendable {
    public let command: CommandItem
    public let score: Double
    public var id: String { command.id }

    public init(command: CommandItem, score: Double) {
        self.command = command
        self.score = score
    }
}
