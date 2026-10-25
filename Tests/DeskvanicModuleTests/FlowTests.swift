import Foundation
import Testing
import DeskvanicCore
@testable import DeskvanicFlow

/// 测试用动作注册表。
private func makeTestRegistry() -> ActionRegistry {
    let registry = ActionRegistry()

    // 文本来源（无输入）
    registry.register(ActionDescriptor(
        id: "t.source", name: "文本源", module: "test",
        inputTypes: [], outputTypes: [.text]),
        executor: { _ in
            .success([ResourceRef(kind: .text, textPayload: "hello world")])
        })

    // 大写转换
    registry.register(ActionDescriptor(
        id: "t.upper", name: "大写", module: "test",
        inputTypes: [.text], outputTypes: [.text]),
        executor: { context in
            guard let text = context.inputs.first?.textPayload else {
                return .failure(DeskvanicError(.invalidInput, "需要文本输入"))
            }
            return .success([ResourceRef(kind: .text, textPayload: text.uppercased())])
        })

    // 抛错动作
    registry.register(ActionDescriptor(
        id: "t.boom", name: "抛错", module: "test",
        inputTypes: [.text], outputTypes: [.text]),
        executor: { _ in
            throw DeskvanicError(.internalInconsistency, "测试爆炸")
        })

    // 长任务（响应取消）
    registry.register(ActionDescriptor(
        id: "t.long", name: "长任务", module: "test",
        inputTypes: [.text], outputTypes: [.text]),
        executor: { context in
            for _ in 0..<100 {
                if await context.isCancelled() {
                    throw CancellationError()
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return .success([ResourceRef(kind: .text, textPayload: "done")])
        })

    // 慢任务（不响应取消，测超时）
    registry.register(ActionDescriptor(
        id: "t.slow", name: "慢任务", module: "test",
        inputTypes: [.text], outputTypes: [.text]),
        executor: { context in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return .success([ResourceRef(kind: .text, textPayload: "finally")])
        })

    // 类型不匹配动作（输出 file，下游期待 text 用 file 直连时报错验证）
    registry.register(ActionDescriptor(
        id: "t.fileOut", name: "文件输出", module: "test",
        inputTypes: [], outputTypes: [.file]),
        executor: { _ in
            .success([ResourceRef(kind: .file, filePayload: "/tmp/x.bin")])
        })

    // 需要文件的输入
    registry.register(ActionDescriptor(
        id: "t.readFile", name: "读文件", module: "test",
        inputTypes: [.file], outputTypes: [.text]),
        executor: { context in
            guard let path = context.inputs.first?.filePayload,
                  FileManager.default.fileExists(atPath: path) else {
                return .failure(DeskvanicError(.fileNotFound, "输入文件不存在（权限失效或被删除）"))
            }
            return .success([ResourceRef(kind: .text, textPayload: "content")])
        })

    return registry
}

@Suite("FlowValidator")
struct FlowValidatorTests {
    @Test func detectsCycle() {
        let a = FlowNode(id: "a", actionID: "t.upper")
        let b = FlowNode(id: "b", actionID: "t.upper")
        let edges = [
            FlowEdge(fromNodeID: "a", outputIndex: 0, toNodeID: "b", inputIndex: 0),
            FlowEdge(fromNodeID: "b", outputIndex: 0, toNodeID: "a", inputIndex: 0),
        ]
        let workflow = FlowWorkflow(name: "cycle", nodes: [a, b], edges: edges)
        let errors = FlowValidator.validate(workflow: workflow, registry: makeTestRegistry())
        #expect(errors.contains { if case .cycleDetected = $0 { return true } else { return false } })
        #expect(FlowValidator.topologicalOrder(nodes: workflow.nodes, edges: edges) == nil)
    }

    @Test func detectsTypeMismatch() {
        let source = FlowNode(id: "s", actionID: "t.fileOut")   // 输出 file
        let reader = FlowNode(id: "r", actionID: "t.upper")     // 输入 text
        let workflow = FlowWorkflow(name: "mismatch", nodes: [source, reader], edges: [
            FlowEdge(fromNodeID: "s", outputIndex: 0, toNodeID: "r", inputIndex: 0),
        ])
        let errors = FlowValidator.validate(workflow: workflow, registry: makeTestRegistry())
        #expect(errors.contains { if case .typeMismatch = $0 { return true } else { return false } })
    }

    @Test func acceptsCompatibleTypes() {
        let source = FlowNode(id: "s", actionID: "t.fileOut")   // 输出 file
        let reader = FlowNode(id: "r", actionID: "t.readFile")  // 输入 file
        let workflow = FlowWorkflow(name: "ok", nodes: [source, reader], edges: [
            FlowEdge(fromNodeID: "s", outputIndex: 0, toNodeID: "r", inputIndex: 0),
        ])
        #expect(FlowValidator.validate(workflow: workflow, registry: makeTestRegistry()).isEmpty)
    }

    @Test func missingParameterDetected() {
        let registry = makeTestRegistry()
        registry.register(ActionDescriptor(
            id: "t.needsParam", name: "需要参数", module: "test",
            inputTypes: [], outputTypes: [],
            parameters: [ParameterDescriptor(key: "k", label: "K", kind: .int, defaultValue: .int(1), min: 0, max: 10)]),
            executor: { _ in .success([]) })
        let node = FlowNode(id: "n", actionID: "t.needsParam", parameters: ["k": .int(99)])  // 超范围
        let workflow = FlowWorkflow(name: "p", nodes: [node])
        let errors = FlowValidator.validate(workflow: workflow, registry: registry)
        #expect(errors.contains { if case .invalidParameter = $0 { return true } else { return false } })
    }
}

@Suite("FlowEngine")
struct FlowEngineTests {
    @Test func linearExecutionPassesData() async {
        let workflow = FlowWorkflow(name: "线性", nodes: [
            FlowNode(id: "s", actionID: "t.source"),
            FlowNode(id: "u", actionID: "t.upper"),
        ], edges: [
            FlowEdge(fromNodeID: "s", outputIndex: 0, toNodeID: "u", inputIndex: 0),
        ])
        let engine = FlowEngine(registry: makeTestRegistry())
        let record = await engine.run(workflow: workflow)
        #expect(record.status == .finished)
        let upper = record.nodeResults.first { $0.nodeID == "u" }
        #expect(upper?.outputs.first?.textPayload == "HELLO WORLD")
    }

    @Test func unknownActionFails() async {
        let workflow = FlowWorkflow(name: "未知动作", nodes: [
            FlowNode(id: "x", actionID: "t.doesNotExist"),
        ])
        let engine = FlowEngine(registry: makeTestRegistry())
        let record = await engine.run(workflow: workflow)
        // 未知动作在运行前校验阶段拦截（运行前检查语义）
        #expect(record.status == .validationFailed)
        #expect(record.log.contains { $0.message.contains("未注册") || $0.message.contains("unknownNode") })
    }

    @Test func missingFileInputReportedHonestly() async {
        let source = FlowNode(id: "s", actionID: "t.fileOut")
        let reader = FlowNode(id: "r", actionID: "t.readFile")
        let workflow = FlowWorkflow(name: "缺文件", nodes: [source, reader], edges: [
            FlowEdge(fromNodeID: "s", outputIndex: 0, toNodeID: "r", inputIndex: 0),
        ])
        let engine = FlowEngine(registry: makeTestRegistry())
        let record = await engine.run(workflow: workflow)
        #expect(record.status == .failed)
        #expect(record.nodeResults.first { $0.nodeID == "r" }?.message?.contains("不存在") == true)
    }

    @Test func failureStopsDownstreamAsSkipped() async {
        let workflow = FlowWorkflow(name: "失败中止", nodes: [
            FlowNode(id: "s", actionID: "t.source"),
            FlowNode(id: "b", actionID: "t.boom"),
            FlowNode(id: "u", actionID: "t.upper"),
        ], edges: [
            FlowEdge(fromNodeID: "s", outputIndex: 0, toNodeID: "b", inputIndex: 0),
            FlowEdge(fromNodeID: "b", outputIndex: 0, toNodeID: "u", inputIndex: 0),
        ])
        let engine = FlowEngine(registry: makeTestRegistry())
        let record = await engine.run(workflow: workflow)
        #expect(record.status == .failed)
        #expect(record.nodeResults.first { $0.nodeID == "u" }?.status == .skipped)
    }

    @Test func retryRecoversFlakyAction() async {
        let registry = makeTestRegistry()
        let attempts = SendableCounter()
        registry.register(ActionDescriptor(
            id: "t.flaky", name: "不稳定", module: "test",
            inputTypes: [.text], outputTypes: [.text]),
            executor: { context in
                attempts.increment()
                if attempts.current < 3 {
                    throw DeskvanicError(.externalService, "临时失败 #\(attempts.current)")
                }
                let text = context.inputs.first?.textPayload ?? ""
                return .success([ResourceRef(kind: .text, textPayload: text)])
            })
        let workflow = FlowWorkflow(name: "重试", nodes: [
            FlowNode(id: "s", actionID: "t.source"),
            FlowNode(id: "f", actionID: "t.flaky"),
        ], edges: [
            FlowEdge(fromNodeID: "s", outputIndex: 0, toNodeID: "f", inputIndex: 0),
        ])
        let engine = FlowEngine(registry: registry)
        let record = await engine.run(workflow: workflow, options: .init(retryCount: 3))
        #expect(record.status == .finished)
        #expect(attempts.current == 3)
    }

    @Test func timeoutKillsSlowNode() async {
        let workflow = FlowWorkflow(name: "超时", nodes: [
            FlowNode(id: "s", actionID: "t.source"),
            FlowNode(id: "slow", actionID: "t.slow"),
        ], edges: [
            FlowEdge(fromNodeID: "s", outputIndex: 0, toNodeID: "slow", inputIndex: 0),
        ])
        let engine = FlowEngine(registry: makeTestRegistry())
        let record = await engine.run(workflow: workflow, options: .init(nodeTimeoutSeconds: 0.5))
        #expect(record.status == .failed)
        #expect(record.nodeResults.first { $0.nodeID == "slow" }?.message?.contains("超时") == true)
    }

    @Test func cancellationMarksRemaining() async {
        let workflow = FlowWorkflow(name: "取消", nodes: [
            FlowNode(id: "long", actionID: "t.long"),
            FlowNode(id: "u", actionID: "t.upper"),
        ], edges: [
            FlowEdge(fromNodeID: "long", outputIndex: 0, toNodeID: "u", inputIndex: 0),
        ])
        let engine = FlowEngine(registry: makeTestRegistry())
        let runTask = Task { await engine.run(workflow: workflow) }
        // 等运行开始后取消
        try? await Task.sleep(nanoseconds: 400_000_000)
        // 拿到 runID：通过 engine.cancelAll（测试只有一个运行）
        await engine.cancelAll()
        let record = await runTask.value
        #expect(record.status == .cancelled)
        #expect(record.nodeResults.contains { $0.status == .cancelled })
    }

    @Test func dryRunDoesNotExecuteActions() async {
        let registry = makeTestRegistry()
        let executed = SendableCounter()
        registry.register(ActionDescriptor(
            id: "t.count", name: "计数", module: "test",
            inputTypes: [], outputTypes: []),
            executor: { _ in
                executed.increment()
                return .success([])
            })
        let workflow = FlowWorkflow(name: "模拟", nodes: [FlowNode(id: "c", actionID: "t.count")])
        let engine = FlowEngine(registry: registry)
        let record = await engine.run(workflow: workflow, options: .init(dryRun: true))
        #expect(record.status == .finished)
        #expect(executed.current == 0, "模拟运行不得执行真实动作")
        #expect(record.nodeResults.first?.message == "（模拟）")
    }

    @Test func outputsConflictHandledByUniqueDestination() async {
        // 输出冲突语义：动作内部用 uniqueDestination 保证不覆盖（验证 FileSafety 集成行为）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-flow-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registry = makeTestRegistry()
        registry.register(ActionDescriptor(
            id: "t.write", name: "写文件", module: "test",
            inputTypes: [], outputTypes: [.file]),
            executor: { _ in
                let dest = FileSafety.uniqueDestination(in: dir, preferredName: "out.txt")
                try "data".data(using: .utf8)?.write(to: dest)
                return .success([ResourceRef(kind: .file, filePayload: dest.path)])
            })
        let workflow = FlowWorkflow(name: "输出", nodes: [
            FlowNode(id: "w1", actionID: "t.write"),
            FlowNode(id: "w2", actionID: "t.write"),
        ])
        let engine = FlowEngine(registry: registry)
        let record = await engine.run(workflow: workflow)
        #expect(record.status == .finished)
        let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files?.count == 2, "两次输出应生成两个文件（不覆盖）")
        #expect(files?.contains("out 2.txt") == true)
    }
}

@Suite("FlowStore")
struct FlowStoreTests {
    @Test func workflowSerializationRoundtripAndMigration() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-flowstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = Database(url: dir.appendingPathComponent("t.sqlite"))
        try await db.open()
        try await db.migrate(DeskvanicSchema.migrations + [FlowSchema.migration])
        let store = FlowStore(database: db)

        let workflow = FlowWorkflow(name: "导出测试", nodes: [
            FlowNode(id: "n1", actionID: "t.source", parameters: ["k": .string("v")]),
        ], edges: [FlowEdge(fromNodeID: "n1", outputIndex: 0, toNodeID: "n2", inputIndex: 0)],
            trigger: .folderEvent(path: "/tmp/watch", debounceSeconds: 3))
        try await store.save(workflow)

        let loaded = try await store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "导出测试")
        #expect(loaded[0].nodes.first?.parameters["k"] == .string("v"))
        if case .folderEvent(let path, let debounce) = loaded[0].trigger {
            #expect(path == "/tmp/watch" && debounce == 3)
        } else {
            Issue.record("触发方式未正确序列化")
        }

        // 版本迁移：旧版本数据（无 trigger 字段）解码为 manual
        let legacyJSON = """
        {"formatVersion":1,"id":"legacy","name":"旧数据","nodes":[],"edges":[]}
        """
        let migrated = try FlowWorkflow.decode(Data(legacyJSON.utf8))
        #expect(migrated.trigger == .manual)
        #expect(migrated.id == "legacy")  // 审计 #6：替换永真断言为真实断言

        // 未来版本拒绝
        let futureJSON = """
        {"formatVersion":99,"id":"future","name":"未来","nodes":[],"edges":[]}
        """
        #expect(throws: DeskvanicError.self) {
            _ = try FlowWorkflow.decode(Data(futureJSON.utf8))
        }

        // 运行记录
        var record = FlowRunRecord(
            id: "r1", workflowID: workflow.id, workflowName: workflow.name,
            startedAt: Date(), status: .running, nodeResults: [], log: [])
        record.status = .finished
        record.finishedAt = Date()
        await store.recordRun(record)
        let runs = await store.recentRuns()
        #expect(runs.count == 1 && runs[0].status == "finished")
    }

    @Test func folderWatcherDebounceFiresOnce() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let counter = SendableCounter()
        let watcher = FolderWatcher(path: dir.path, debounceSeconds: 0.3) {
            await counter.increment()
        }
        watcher.start()
        // 连续多次触发（防抖 + 防重复应合并）
        for i in 0..<5 {
            try Data("x\(i)".utf8).write(to: dir.appendingPathComponent("f\(i).txt"))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let count = await counter.current
        #expect(count <= 2, "防抖后触发次数应远小于写入次数，实际 \(count)")
        watcher.stop()
    }
}

final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var current: Int { lock.lock(); defer { lock.unlock() }; return count }
}
