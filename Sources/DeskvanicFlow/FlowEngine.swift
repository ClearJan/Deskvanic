import Foundation
import DeskvanicCore

/// 工作流执行引擎：拓扑顺序执行真实动作，支持取消、节点超时、重试、模拟运行。
public actor FlowEngine {

    public struct Options: Sendable {
        /// 每节点超时（秒）；nil 表示不限。
        public var nodeTimeoutSeconds: Double?
        /// 失败重试次数（0 = 不重试）。
        public var retryCount: Int = 0
        /// 模拟运行：执行校验与图遍历，但不真正运行业务动作。
        public var dryRun: Bool = false

        public init(nodeTimeoutSeconds: Double? = nil, retryCount: Int = 0, dryRun: Bool = false) {
            self.nodeTimeoutSeconds = nodeTimeoutSeconds
            self.retryCount = retryCount
            self.dryRun = dryRun
        }
    }

    private let registry: ActionRegistry
    private var runningTask: Task<Void, Never>?
    private var cancellationFlags: [String: Bool] = [:]   // runID → cancelled

    public init(registry: ActionRegistry) {
        self.registry = registry
    }

    // MARK: - 执行

    /// 执行工作流。返回完整运行记录（含每节点输出）。
    @discardableResult
    public func run(
        workflow: FlowWorkflow, inputs: [ResourceRef] = [],
        options: Options = Options()
    ) async -> FlowRunRecord {
        // 输入参数修正：inputs 为首个节点的输入（或独立入口）
        var record = FlowRunRecord(
            id: UUID().uuidString, workflowID: workflow.id, workflowName: workflow.name,
            startedAt: Date(), status: .running,
            nodeResults: workflow.nodes.map { node in
                FlowRunRecord.NodeResult(nodeID: node.id, actionID: node.actionID, status: .pending, message: nil, outputs: [])
            },
            log: [])

        // 校验
        let errors = FlowValidator.validate(workflow: workflow, registry: registry)
        if !errors.isEmpty {
            record.status = .validationFailed
            for error in errors {
                record.log.append(FlowRunRecord.LogEntry(time: Date(), message: "校验失败：\(String(describing: error))"))
            }
            record.finishedAt = Date()
            return record
        }

        guard let order = FlowValidator.topologicalOrder(nodes: workflow.nodes, edges: workflow.edges) else {
            record.status = .validationFailed
            record.log.append(FlowRunRecord.LogEntry(time: Date(), message: "存在循环依赖"))
            record.finishedAt = Date()
            return record
        }

        let nodeByID = Dictionary(uniqueKeysWithValues: workflow.nodes.map { ($0.id, $0) })
        let runID = record.id
        cancellationFlags[runID] = false

        record.log.append(FlowRunRecord.LogEntry(
            time: Date(),
            message: options.dryRun ? "模拟运行开始（不执行真实动作）" : "开始执行 \(workflow.nodes.count) 个节点"))

        // 逐节点执行（拓扑序）；输出按边传递
        var outputsByNode: [String: [ResourceRef]] = [:]
        var globalInputs = inputs

        executionLoop: for nodeID in order {
            if cancelled(runID: runID) {
                markRemainingCancelled(record: &record, from: nodeID, order: order)
                record.status = .cancelled
                record.finishedAt = Date()
                cancellationFlags[runID] = nil
                return record
            }

            let nodeActionID = nodeByID[nodeID]?.actionID ?? nodeID
            guard let node = nodeByID[nodeID],
                  let descriptor = registry.descriptor(for: node.actionID),
                  let executor = registry.executor(for: node.actionID) else {
                updateNode(record: &record, nodeID: nodeID) {
                    $0.status = .failed
                    $0.message = "动作未注册：\(nodeActionID)"
                }
                record.status = .failed
                record.finishedAt = Date()
                cancellationFlags[runID] = nil
                return record
            }

            // 收集该节点的输入：边连入的输出 + （首个节点）全局输入
            var nodeInputs: [ResourceRef] = []
            var hasConnectedInput = false
            for edge in workflow.edges where edge.toNodeID == nodeID {
                hasConnectedInput = true
                if let sourceOutputs = outputsByNode[edge.fromNodeID],
                   edge.outputIndex < sourceOutputs.count {
                    while nodeInputs.count <= edge.inputIndex {
                        nodeInputs.append(ResourceRef(kind: .text, textPayload: ""))
                    }
                    nodeInputs[edge.inputIndex] = sourceOutputs[edge.outputIndex]
                }
            }
            if !hasConnectedInput && nodeInputs.isEmpty && !globalInputs.isEmpty {
                nodeInputs = globalInputs
                globalInputs = []
            }

            updateNode(record: &record, nodeID: nodeID) { $0.status = .running }

            // 模拟运行：只走图，不执行
            if options.dryRun {
                updateNode(record: &record, nodeID: nodeID) {
                    $0.status = .finished
                    $0.message = "（模拟）"
                }
                record.log.append(FlowRunRecord.LogEntry(time: Date(), message: "模拟：\(descriptor.name)"))
                continue
            }

            // 参数最终检查
            for parameter in descriptor.parameters {
                guard node.parameters[parameter.key] != nil else {
                    updateNode(record: &record, nodeID: nodeID) {
                        $0.status = .failed
                        $0.message = "缺少参数：\(parameter.label)"
                    }
                    record.status = .failed
                    record.finishedAt = Date()
                    cancellationFlags[runID] = nil
                    break executionLoop
                }
            }

            let context = ActionContext(
                inputs: nodeInputs, parameters: node.parameters, nodeID: node.id,
                isCancelled: { [weak self] in
                    guard let self else { return false }
                    return await self.isRunCancelled(runID: runID)
                },
                reportProgress: { fraction, message in
                    Task {
                        await self.reportNodeProgress(record: runID, nodeID: nodeID, fraction: fraction, message: message)
                    }
                })

            // 带超时与重试的执行
            var attempt = 0
            var outcome: ActionOutcome?
            while attempt <= options.retryCount {
                if cancelled(runID: runID) {
                    outcome = .failure(.cancellation())
                    break
                }
                outcome = await executeWithTimeout(
                    executor: executor, context: context,
                    timeout: options.nodeTimeoutSeconds)
                if let outcome, outcome.error == nil {
                    break  // 成功
                }
                attempt += 1
                if attempt <= options.retryCount {
                    record.log.append(FlowRunRecord.LogEntry(
                        time: Date(), message: "节点 \(descriptor.name) 失败，重试 \(attempt)/\(options.retryCount)"))
                }
            }

            if let outcome, outcome.error == nil {
                // 成功
                outputsByNode[nodeID] = outcome.outputs
                updateNode(record: &record, nodeID: nodeID) {
                    $0.status = .finished
                    $0.message = outcome.message
                    $0.outputs = outcome.outputs
                }
                record.log.append(FlowRunRecord.LogEntry(
                    time: Date(), message: "完成：\(descriptor.name)\(outcome.message.map { "（\($0)）" } ?? "")"))
            } else {
                // 失败 / 超时 / 取消
                let text: String
                if outcome == nil {
                    text = "节点超时（超过 \(options.nodeTimeoutSeconds ?? 0)s）"
                } else if let error = outcome?.error {
                    text = String(describing: error)
                } else {
                    text = "未知错误"
                }
                if cancelled(runID: runID) {
                    updateNode(record: &record, nodeID: nodeID) {
                        $0.status = .cancelled
                        $0.message = "已取消"
                    }
                    markRemainingCancelled(record: &record, from: nodeID, order: order, skipFirst: true)
                    record.status = .cancelled
                    record.finishedAt = Date()
                    cancellationFlags[runID] = nil
                    return record
                }
                updateNode(record: &record, nodeID: nodeID) {
                    $0.status = .failed
                    $0.message = text
                }
                record.log.append(FlowRunRecord.LogEntry(time: Date(), message: "失败：\(descriptor.name) — \(text)"))
                // 失败语义：中止后续节点（保留已完成输出）
                markRemainingCancelled(record: &record, from: nodeID, order: order, skipFirst: true, asSkipped: true)
                record.status = .failed
                record.finishedAt = Date()
                cancellationFlags[runID] = nil
                break executionLoop
            }
        }

        if record.status == .running {
            record.status = .finished
        }
        record.finishedAt = Date()
        cancellationFlags[runID] = nil
        record.log.append(FlowRunRecord.LogEntry(
            time: Date(),
            message: "运行结束：\(record.status.rawValue)，耗时 \(String(format: "%.2f", (record.finishedAt! - record.startedAt)))s"))
        return record
    }

    /// 取消正在运行的流程。
    public func cancel(runID: String) {
        cancellationFlags[runID] = true
    }

    public func cancelAll() {
        for key in cancellationFlags.keys {
            cancellationFlags[key] = true
        }
    }

    // MARK: - 内部

    private func cancelled(runID: String) -> Bool {
        cancellationFlags[runID] ?? false
    }

    private func isRunCancelled(runID: String) async -> Bool {
        cancelled(runID: runID)
    }

    private func reportNodeProgress(record runID: String, nodeID: String, fraction: Double, message: String?) {
        // 进度仅记录到日志（轻量实现）
        if let message {
            Log.debug("流程 \(runID) 节点 \(nodeID) 进度 \(Int(fraction * 100))%：\(message)", category: .flow)
        }
    }

    /// 带超时执行单个动作。
    private func executeWithTimeout(
        executor: @escaping @Sendable (ActionContext) async throws -> ActionOutcome,
        context: ActionContext,
        timeout: Double?
    ) async -> ActionOutcome {
        func runOnce() async -> ActionOutcome {
            do {
                return try await executor(context)
            } catch is CancellationError {
                return .failure(.cancellation())
            } catch let error as DeskvanicError {
                return .failure(error)
            } catch {
                return .failure(error.asDeskvanicError())
            }
        }
        guard let timeout else {
            return await runOnce()
        }
        return await withTaskGroup(of: ActionOutcome.self) { group in
            group.addTask { await runOnce() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .failure(DeskvanicError(.timeout, "节点执行超时（\(timeout)s）"))
            }
            let first = await group.next() ?? .failure(DeskvanicError(.internalInconsistency, "无结果"))
            group.cancelAll()
            return first
        }
    }

    private func updateNode(record: inout FlowRunRecord, nodeID: String, update: (inout FlowRunRecord.NodeResult) -> Void) {
        guard let index = record.nodeResults.firstIndex(where: { $0.nodeID == nodeID }) else { return }
        update(&record.nodeResults[index])
    }

    private func markRemainingCancelled(
        record: inout FlowRunRecord, from nodeID: String, order: [String],
        skipFirst: Bool = false, asSkipped: Bool = false
    ) {
        guard let startIndex = order.firstIndex(of: nodeID) else { return }
        let rangeStart = skipFirst ? startIndex + 1 : startIndex
        for remainingID in order[rangeStart...] {
            updateNode(record: &record, nodeID: remainingID) {
                $0.status = asSkipped ? .skipped : .cancelled
            }
        }
    }
}

extension Date {
    static func - (lhs: Date, rhs: Date) -> TimeInterval {
        lhs.timeIntervalSince(rhs)
    }
}
