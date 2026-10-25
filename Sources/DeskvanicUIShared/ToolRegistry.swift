import DeskvanicCore
import SwiftUI

/// 工具注册协议：每个功能模块向应用宿主注册自己的入口。
/// 宿主不感知模块内部实现，模块之间也不互相依赖。
public protocol ToolModule: Identifiable where ID == String {
    var name: String { get }
    var nameEn: String { get }
    var icon: String { get }          // SF Symbol
    var summary: String { get }
    var section: ToolSection { get }
    @MainActor func makeView() -> AnyView
}

public enum ToolSection: String, CaseIterable, Sendable {
    case essentials = "高频工具"
    case files = "文件与资料"
    case system = "系统能力"
    case advanced = "进阶能力"

    public var order: Int {
        switch self {
        case .essentials: return 0
        case .files: return 1
        case .system: return 2
        case .advanced: return 3
        }
    }
}

/// 注册表中的具体条目：避免在存在类型上做 KeyPath / ForEach。
public struct ToolEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let nameEn: String
    public let icon: String
    public let summary: String
    public let section: ToolSection
    public let moduleID: String   // 稳定工具标识

    public init(tool: any ToolModule) {
        self.id = tool.id
        self.name = tool.name
        self.nameEn = tool.nameEn
        self.icon = tool.icon
        self.summary = tool.summary
        self.section = tool.section
        self.moduleID = tool.id
    }
}

/// 全局工具注册表：主窗口、命令面板、菜单栏共用同一份目录。
@MainActor
public final class ToolRegistry: ObservableObject {
    public static let shared = ToolRegistry()

    @Published public private(set) var entries: [ToolEntry] = []
    private var modules: [String: any ToolModule] = [:]

    public init() {}

    public func register(_ tool: any ToolModule) {
        guard modules[tool.id] == nil else {
            Log.warning("工具重复注册被忽略: \(tool.id)", category: .ui)
            return
        }
        modules[tool.id] = tool
        entries.append(ToolEntry(tool: tool))
        entries.sort { lhs, rhs in
            if lhs.section != rhs.section { return lhs.section.order < rhs.section.order }
            return lhs.name < rhs.name
        }
    }

    public func module(id: String) -> (any ToolModule)? {
        modules[id]
    }

    public var allModuleIDs: [String] { Array(modules.keys) }
}

/// 通用工具容器视图，统一导航标题。
public struct ToolContainer<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(title)
        .navigationSubtitle(subtitle ?? "")
    }
}
