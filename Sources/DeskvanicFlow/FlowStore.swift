import Dispatch
import Foundation
import os
import DeskvanicCore

/// 工作流持久化（数据库 v9：workflows + runs）。
public actor FlowStore {
    private let db: Database

    public init(database: Database) {
        self.db = database
    }

    // MARK: - 工作流

    public func save(_ workflow: FlowWorkflow) async throws {
        let data = try workflow.encoded()
        _ = try await db.runUpdate(
            "INSERT OR REPLACE INTO workflows(id, name, data, updated_at) VALUES(?,?,?,?)",
            [.text(workflow.id), .text(workflow.name), .blob(data), .text(DateCodec.encode(Date()))])
    }

    public func delete(id: String) async throws {
        _ = try await db.runUpdate("DELETE FROM workflows WHERE id = ?", [.text(id)])
    }

    public func loadAll() async throws -> [FlowWorkflow] {
        let rows = try await db.run("SELECT data FROM workflows ORDER BY updated_at DESC")
        return rows.compactMap { row in
            guard let data = row["data"]?.blobValue else { return nil }
            return try? FlowWorkflow.decode(data)
        }
    }

    public func load(id: String) async throws -> FlowWorkflow? {
        let rows = try await db.run("SELECT data FROM workflows WHERE id = ?", [.text(id)])
        guard let data = rows.first?["data"]?.blobValue else { return nil }
        return try FlowWorkflow.decode(data)
    }

    // MARK: - 运行记录

    public func recordRun(_ record: FlowRunRecord) async {
        let nodeSummary = record.nodeResults
            .map { "\($0.actionID):\($0.status.rawValue)" }
            .joined(separator: "\n")
        let logText = record.log
            .map { "[\(DateCodec.encode($0.time))] \($0.message)" }
            .joined(separator: "\n")
        _ = try? await db.runUpdate(
            "INSERT INTO flow_runs(id, workflow_id, status, node_summary, log, started_at, finished_at) VALUES(?,?,?,?,?,?,?)",
            [.text(record.id), .text(record.workflowID), .text(record.status.rawValue),
             .text(nodeSummary), .text(logText),
             .text(DateCodec.encode(record.startedAt)),
             record.finishedAt.map { .text(DateCodec.encode($0)) } ?? .null])
    }

    public struct RunSummary: Identifiable, Sendable {
        public let id: String
        public let workflowID: String
        public let status: String
        public let nodeSummary: String
        public let startedAt: String
    }

    public func recentRuns(limit: Int = 50) async -> [RunSummary] {
        let rows = (try? await db.run(
            "SELECT id, workflow_id, status, node_summary, started_at FROM flow_runs ORDER BY started_at DESC LIMIT ?",
            [.int(Int64(limit))])) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.stringValue,
                  let workflowID = row["workflow_id"]?.stringValue,
                  let status = row["status"]?.stringValue,
                  let startedAt = row["started_at"]?.stringValue else { return nil }
            return RunSummary(
                id: id, workflowID: workflowID, status: status,
                nodeSummary: row["node_summary"]?.stringValue ?? "",
                startedAt: startedAt)
        }
    }
}

/// FlowEngine 数据库迁移（版本 9）。
public enum FlowSchema {
    public static let migration = DBMigration(version: 9, name: "flow-engine", statements: [
        """
        CREATE TABLE workflows(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            data BLOB NOT NULL,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE flow_runs(
            id TEXT PRIMARY KEY,
            workflow_id TEXT NOT NULL,
            status TEXT NOT NULL,
            node_summary TEXT NOT NULL DEFAULT '',
            log TEXT NOT NULL DEFAULT '',
            started_at TEXT NOT NULL,
            finished_at TEXT
        )
        """,
        "CREATE INDEX idx_flow_runs_started ON flow_runs(started_at DESC)",
    ])
}

/// 文件夹事件监视器：DispatchSource 文件系统监视 + 防抖。
/// 防重复触发：事件处理期间抑制新事件；处理完成后重新武装。
public final class FolderWatcher: @unchecked Sendable {
    private let path: String
    private let debounce: TimeInterval
    private var source: DispatchSourceFileSystemObject?
    private let armedState = OSAllocatedUnfairLock(initialState: true)
    private var debounceTask: DispatchWorkItem?
    private let onEvent: @Sendable () async -> Void

    public init(path: String, debounceSeconds: TimeInterval = 2.0, onEvent: @escaping @Sendable () async -> Void) {
        self.path = path
        self.debounce = debounceSeconds
        self.onEvent = onEvent
    }

    public func start() {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.warning("文件夹监视失败（无法打开）：\(path)", category: .flow)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.scheduleDebounced()
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        self.source = source
        Log.info("文件夹监视已启动：\(path)", category: .flow)
    }

    private func scheduleDebounced() {
        // 防重复触发：未武装时忽略
        let wasArmed = armedState.withLock { state -> Bool in
            let was = state
            state = false
            return was
        }
        guard wasArmed else { return }

        debounceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task {
                await self.onEvent()
                // 处理完成后重新武装
                self.armedState.withLock { $0 = true }
            }
        }
        debounceTask = task
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + debounce, execute: task)
    }

    public func stop() {
        armedState.withLock { $0 = true }
        debounceTask?.cancel()
        source?.cancel()
        source = nil
    }
}
