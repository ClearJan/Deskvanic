import Foundation
import DeskvanicCore

/// 动作注册表：宿主在启动时注册各模块的真实业务能力。
/// 引擎只依赖这里的元数据与执行器，不直接依赖业务模块。
public final class ActionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [String: ActionDescriptor] = [:]
    private var executors: [String: @Sendable (ActionContext) async throws -> ActionOutcome] = [:]

    public init() {}

    /// 注册动作（描述符 + 执行器）。同 ID 重复注册覆盖后者。
    public func register(
        _ descriptor: ActionDescriptor,
        executor: @escaping @Sendable (ActionContext) async throws -> ActionOutcome
    ) {
        lock.lock()
        descriptors[descriptor.id] = descriptor
        executors[descriptor.id] = executor
        lock.unlock()
    }

    public func descriptor(for id: String) -> ActionDescriptor? {
        lock.lock(); defer { lock.unlock() }
        return descriptors[id]
    }

    public var allDescriptors: [ActionDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return descriptors.values.sorted { $0.id < $1.id }
    }

    func executor(for id: String) -> (@Sendable (ActionContext) async throws -> ActionOutcome)? {
        lock.lock(); defer { lock.unlock() }
        return executors[id]
    }
}

/// 动作执行上下文。
public struct ActionContext: Sendable {
    /// 输入资源（按输入口索引）。
    public let inputs: [ResourceRef]
    /// 节点参数（已通过校验）。
    public let parameters: [String: ParameterValue]
    /// 节点 ID（日志用）。
    public let nodeID: String
    /// 取消检查：长任务应周期性调用，返回 true 时尽快以 CancellationError 退出。
    public let isCancelled: @Sendable () async -> Bool
    /// 进度报告（0...1）。
    public let reportProgress: @Sendable (Double, String?) -> Void

    public func parameter(_ key: String) -> ParameterValue? {
        parameters[key]
    }

    public func stringParameter(_ key: String) -> String? {
        if case .string(let value)? = parameters[key] { return value }
        return nil
    }

    public func intParameter(_ key: String) -> Int? {
        switch parameters[key] {
        case .int(let value): return value
        default: return nil
        }
    }

    public func doubleParameter(_ key: String) -> Double? {
        switch parameters[key] {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public func boolParameter(_ key: String) -> Bool? {
        if case .bool(let value)? = parameters[key] { return value }
        return nil
    }
}

/// 工作流执行结果。
public struct FlowRunRecord: Sendable, Identifiable {
    public let id: String
    public let workflowID: String
    public let workflowName: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var nodeResults: [NodeResult]
    public var log: [LogEntry]

    public enum Status: String, Codable, Sendable {
        case running, finished, failed, cancelled, validationFailed
    }

    public struct NodeResult: Sendable {
        public let nodeID: String
        public let actionID: String
        public var status: NodeStatus
        public var message: String?
        public var outputs: [ResourceRef]

        public enum NodeStatus: String, Sendable {
            case pending, running, finished, failed, skipped, cancelled
        }
    }

    public struct LogEntry: Sendable {
        public let time: Date
        public let message: String
    }
}
