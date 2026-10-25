import Foundation
import DeskvanicCore

/// 工作流节点：调用真实业务动作。
public struct FlowNode: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let actionID: String          // ActionDescriptor.id（如 "file.convertImage"）
    public var parameters: [String: ParameterValue]
    public var position: CGPointInfo     // 仅 UI 用

    public struct CGPointInfo: Codable, Hashable, Sendable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public init(id: String = UUID().uuidString, actionID: String,
                parameters: [String: ParameterValue] = [:], position: CGPointInfo = .init(x: 0, y: 0)) {
        self.id = id
        self.actionID = actionID
        self.parameters = parameters
        self.position = position
    }
}

/// 连线：源节点输出口 → 目标节点输入口。
public struct FlowEdge: Codable, Hashable, Sendable {
    public let fromNodeID: String
    public let outputIndex: Int
    public let toNodeID: String
    public let inputIndex: Int

    public init(fromNodeID: String, outputIndex: Int, toNodeID: String, inputIndex: Int) {
        self.fromNodeID = fromNodeID
        self.outputIndex = outputIndex
        self.toNodeID = toNodeID
        self.inputIndex = inputIndex
    }
}

/// 工作流定义（版本化序列化，v1）。
public struct FlowWorkflow: Codable, Sendable, Identifiable {
    public static let formatVersion = 1

    public var formatVersion: Int
    public let id: String
    public var name: String
    public var nodes: [FlowNode]
    public var edges: [FlowEdge]
    /// 触发方式：手动 / 文件夹事件。
    public var trigger: Trigger
    public let createdAt: Date

    public enum Trigger: Codable, Hashable, Sendable {
        case manual
        case folderEvent(path: String, debounceSeconds: Double)
    }

    public init(id: String = UUID().uuidString, name: String,
                nodes: [FlowNode] = [], edges: [FlowEdge] = [],
                trigger: Trigger = .manual, createdAt: Date = Date()) {
        self.formatVersion = Self.formatVersion
        self.id = id
        self.name = name
        self.nodes = nodes
        self.edges = edges
        self.trigger = trigger
        self.createdAt = createdAt
    }

    // MARK: - 序列化（版本迁移点）

    public func encoded() throws -> Data {
        var copy = self
        copy.formatVersion = Self.formatVersion
        return try JSONEncoder.flowEncoder.encode(copy)
    }

    public static func decode(_ data: Data) throws -> FlowWorkflow {
        let decoder = JSONDecoder.flowDecoder
        let raw = try decoder.decode(RawWorkflow.self, from: data)
        return try migrate(raw: raw)
    }

    /// 版本迁移：v1 为初始版本；后续版本在此追加分支。
    static func migrate(raw: RawWorkflow) throws -> FlowWorkflow {
        switch raw.formatVersion {
        case 1:
            return FlowWorkflow(
                id: raw.id, name: raw.name, nodes: raw.nodes, edges: raw.edges,
                trigger: raw.trigger ?? .manual, createdAt: raw.createdAt ?? Date())
        default:
            throw DeskvanicError(
                .invalidInput,
                "工作流格式版本不支持：\(raw.formatVersion)（当前支持 ≤\(formatVersion)）",
                recovery: "请升级 Deskvanic。")
        }
    }

    /// 兼容旧 JSON 的原始解码形状。
    struct RawWorkflow: Codable {
        var formatVersion: Int
        var id: String
        var name: String
        var nodes: [FlowNode]
        var edges: [FlowEdge]
        var trigger: Trigger?
        var createdAt: Date?
    }
}

extension JSONEncoder {
    static let flowEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let flowDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// 校验错误。
public enum FlowValidationError: Error, Sendable {
    case cycleDetected
    case unknownNode(String)
    case typeMismatch(from: String, to: String, detail: String)
    case missingParameter(nodeID: String, key: String)
    case invalidParameter(nodeID: String, key: String, reason: String)
    case disconnectedInput(nodeID: String, inputIndex: Int)
}

/// 校验：环检测、连线类型匹配、参数合法性。
public enum FlowValidator {

    /// 拓扑排序（Kahn）。有环返回 nil。
    public static func topologicalOrder(nodes: [FlowNode], edges: [FlowEdge]) -> [String]? {
        var inDegree: [String: Int] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        var adjacency: [String: [String]] = [:]
        for edge in edges {
            guard inDegree[edge.toNodeID] != nil, inDegree[edge.fromNodeID] != nil else { continue }
            inDegree[edge.toNodeID, default: 0] += 1
            adjacency[edge.fromNodeID, default: []].append(edge.toNodeID)
        }
        var queue = nodes.filter { inDegree[$0.id] == 0 }.map(\.id)
        var order: [String] = []
        while let nodeID = queue.first {
            queue.removeFirst()
            order.append(nodeID)
            for next in adjacency[nodeID] ?? [] {
                inDegree[next]? -= 1
                if inDegree[next] == 0 {
                    queue.append(next)
                }
            }
        }
        return order.count == nodes.count ? order : nil
    }

    /// 全面校验。registry 提供动作元数据。
    public static func validate(
        workflow: FlowWorkflow,
        registry: ActionRegistry
    ) -> [FlowValidationError] {
        var errors: [FlowValidationError] = []
        let nodeByID = Dictionary(uniqueKeysWithValues: workflow.nodes.map { ($0.id, $0) })

        // 环
        if topologicalOrder(nodes: workflow.nodes, edges: workflow.edges) == nil {
            errors.append(.cycleDetected)
        }

        // 边类型检查
        for edge in workflow.edges {
            guard let fromNode = nodeByID[edge.fromNodeID],
                  let toNode = nodeByID[edge.toNodeID] else {
                errors.append(.unknownNode(edge.fromNodeID))
                continue
            }
            guard let fromDescriptor = registry.descriptor(for: fromNode.actionID),
                  let toDescriptor = registry.descriptor(for: toNode.actionID) else {
                errors.append(.unknownNode(fromNode.actionID))
                continue
            }
            let outputTypes = fromDescriptor.outputTypes
            let inputTypes = toDescriptor.inputTypes
            guard edge.outputIndex < outputTypes.count, edge.inputIndex < inputTypes.count else {
                errors.append(.typeMismatch(
                    from: fromNode.actionID, to: toNode.actionID, detail: "端口索引越界"))
                continue
            }
            let outputType = outputTypes[edge.outputIndex]
            let inputType = inputTypes[edge.inputIndex]
            if !inputType.accepts(outputType) {
                errors.append(.typeMismatch(
                    from: fromNode.actionID, to: toNode.actionID,
                    detail: "\(outputType.rawValue) 不能连接到 \(inputType.rawValue)"))
            }
        }

        // 参数校验
        for node in workflow.nodes {
            guard let descriptor = registry.descriptor(for: node.actionID) else {
                errors.append(.unknownNode(node.actionID))
                continue
            }
            for parameter in descriptor.parameters {
                guard let value = node.parameters[parameter.key] else {
                    errors.append(.missingParameter(nodeID: node.id, key: parameter.key))
                    continue
                }
                if !value.validate(against: parameter) {
                    errors.append(.invalidParameter(nodeID: node.id, key: parameter.key,
                                                    reason: "超出范围或选项非法"))
                }
            }
        }
        return errors
    }
}
