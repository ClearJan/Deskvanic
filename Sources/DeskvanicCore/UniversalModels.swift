import Foundation

// MARK: - 统一数据协议（第 8 节）
// 跨模块传递的资源与工作流动作必须使用这些稳定模型，
// 禁止用无约束字典或字符串拼接代替核心数据协议。

/// 资源种类：涵盖所有模块可交换的内容类型。
public enum ResourceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case text
    case url
    case file
    case image
    case pdf
    case audio
    case video
    case capture        // 截图/录制产物
    case ocrResult      // OCR 文本结果
    case workflowResult // 工作流执行产物

    public var displayName: String {
        switch self {
        case .text: return "文本"
        case .url: return "链接"
        case .file: return "文件"
        case .image: return "图片"
        case .pdf: return "PDF"
        case .audio: return "音频"
        case .video: return "视频"
        case .capture: return "捕获"
        case .ocrResult: return "识别文本"
        case .workflowResult: return "工作流产物"
        }
    }
}

/// 跨模块资源引用：轻量值类型，按需展开为实际内容。
public struct ResourceRef: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kind: ResourceKind
    public var textPayload: String?
    public var urlPayload: String?
    public var filePayload: String?   // 绝对路径
    public var createdAt: Date
    public var originModule: String?  // 产生该资源的模块（审计/展示用）

    public init(
        id: UUID = UUID(),
        kind: ResourceKind,
        textPayload: String? = nil,
        urlPayload: String? = nil,
        filePayload: String? = nil,
        createdAt: Date = Date(),
        originModule: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.textPayload = textPayload
        self.urlPayload = urlPayload
        self.filePayload = filePayload
        self.createdAt = createdAt
        self.originModule = originModule
    }

    public var displayTitle: String {
        switch kind {
        case .text, .ocrResult:
            return String((textPayload ?? "").prefix(80))
        case .url:
            return urlPayload ?? ""
        case .file, .image, .pdf, .audio, .video, .capture, .workflowResult:
            return (filePayload as NSString?)?.lastPathComponent ?? "未命名"
        }
    }
}

// MARK: - 工作流动作契约（M15 Flow Engine 的基础，V1 起冻结接口）

/// 工作流端口类型：动作的输入输出必须类型匹配才能连接。
public enum PortType: String, Codable, Sendable, Hashable {
    case void
    case text
    case url
    case file
    case files       // 文件集合（批处理）
    case image
    case pdf
    case any         // 兼容任意类型（用于通用节点；连接检查按实际值复核）

    public func accepts(_ other: PortType) -> Bool {
        if self == .any || other == .any { return true }
        if self == other { return true }
        // 文件集合可以退化为单个文件，图片/PDF 是文件的子类型。
        switch (self, other) {
        case (.file, .image), (.file, .pdf), (.file, .files),
             (.files, .file), (.files, .image), (.files, .pdf),
             (.image, .file), (.pdf, .file):
            return true
        default:
            return false
        }
    }
}

/// 参数描述：用于参数合法性检查与 UI 自动生成表单。
public struct ParameterDescriptor: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case int, double, string, bool, option, folder
    }
    public let key: String
    public let label: String
    public let kind: Kind
    public let defaultValue: ParameterValue
    public let allowedOptions: [String]
    public let min: Double?
    public let max: Double?

    public init(
        key: String, label: String, kind: Kind, defaultValue: ParameterValue,
        allowedOptions: [String] = [], min: Double? = nil, max: Double? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.defaultValue = defaultValue
        self.allowedOptions = allowedOptions
        self.min = min
        self.max = max
    }
}

/// 参数值：强类型，拒绝字符串拼接式配置。
public enum ParameterValue: Codable, Sendable, Hashable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)

    var numericValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public func validate(against descriptor: ParameterDescriptor) -> Bool {
        switch (self, descriptor.kind) {
        case (.int(let v), .int):
            if let min = descriptor.min, Double(v) < min { return false }
            if let max = descriptor.max, Double(v) > max { return false }
            return true
        case (.double, .double), (.int, .double):
            guard let value = self.numericValue else { return false }
            if let min = descriptor.min, value < min { return false }
            if let max = descriptor.max, value > max { return false }
            return true
        case (.string, .string):
            return true
        case (.string(let s), .option):
            return descriptor.allowedOptions.contains(s)
        case (.bool, .bool):
            return true
        case (.string, .folder):
            return true
        default:
            return false
        }
    }
}

/// 动作描述符：每个可连接到工作流的能力都以此注册。
public struct ActionDescriptor: Codable, Sendable, Hashable, Identifiable {
    public let id: String              // 稳定标识，例如 "file.convertImage"
    public let name: String
    public let module: String
    public let inputTypes: [PortType]
    public let outputTypes: [PortType]
    public let parameters: [ParameterDescriptor]
    public let requiredPermissions: [PermissionKind]
    public let isUndoable: Bool
    public let failureDescription: String

    public init(
        id: String, name: String, module: String,
        inputTypes: [PortType], outputTypes: [PortType],
        parameters: [ParameterDescriptor] = [],
        requiredPermissions: [PermissionKind] = [],
        isUndoable: Bool = false,
        failureDescription: String = "处理失败，输入保持不变"
    ) {
        self.id = id
        self.name = name
        self.module = module
        self.inputTypes = inputTypes
        self.outputTypes = outputTypes
        self.parameters = parameters
        self.requiredPermissions = requiredPermissions
        self.isUndoable = isUndoable
        self.failureDescription = failureDescription
    }
}

/// 动作执行结果。
public struct ActionOutcome: Sendable {
    public let outputs: [ResourceRef]
    public let message: String?
    public let error: DeskvanicError?

    public static func success(_ outputs: [ResourceRef], message: String? = nil) -> ActionOutcome {
        ActionOutcome(outputs: outputs, message: message, error: nil)
    }
    public static func failure(_ error: DeskvanicError) -> ActionOutcome {
        ActionOutcome(outputs: [], message: nil, error: error)
    }
}
