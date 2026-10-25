import Foundation
import os

/// 统一后台任务队列：并发受控、可取消、可观察进度、保留历史记录。
/// 文件批处理、OCR、索引重建等长任务都必须经过此队列，避免阻塞主线程。
public actor TaskQueue {
    public struct JobUpdate: Sendable, Hashable {
        public let id: UUID
        public let title: String
        public let state: JobState
        public let progress: Double?
        public let message: String?
        public let errorText: String?
    }

    public enum JobState: String, Sendable, Codable {
        case queued, running, finished, failed, cancelled
    }

    public struct JobHistoryItem: Sendable, Codable, Identifiable {
        public let id: UUID
        public let title: String
        public let state: JobState
        public let startedAt: Date
        public let finishedAt: Date?
        public let errorText: String?
    }

    /// 传给任务操作体的上下文：报告进度；任务应响应 Task.isCancelled 实现取消。
    public struct JobContext: Sendable {
        public let jobID: UUID
        private let report: @Sendable (Double, String?) -> Void

        init(jobID: UUID, report: @escaping @Sendable (Double, String?) -> Void) {
            self.jobID = jobID
            self.report = report
        }

        public func progress(_ fraction: Double, _ message: String? = nil) {
            report(min(max(fraction, 0), 1), message)
        }
    }

    public static let shared = TaskQueue(name: "main", maxConcurrent: 2)

    public let name: String
    public let maxConcurrent: Int

    /// 未完成任务数（运行中 + 排队中），以锁保护的计数器实现，
    /// 供主线程同步读取（例如退出确认对话框）。
    private let outstanding = OSAllocatedUnfairLock(initialState: 0)
    nonisolated public var outstandingJobCount: Int {
        outstanding.withLock { $0 }
    }

    private struct PendingJob: Sendable {
        let id: UUID
        let title: String
        let operation: @Sendable (JobContext) async throws -> Void
    }

    private struct RunningJob {
        let task: Task<Void, Never>
        let title: String
    }

    private var pending: [PendingJob] = []
    private var running: [UUID: RunningJob] = [:]
    private var history: [JobHistoryItem] = []
    private let historyLimit = 200
    private var continuations: [UUID: AsyncStream<JobUpdate>.Continuation] = [:]
    private var recentUpdates: [JobUpdate] = []

    public init(name: String, maxConcurrent: Int = 2) {
        self.name = name
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// 入队异步操作；返回任务 ID 用于取消或跟踪。
    @discardableResult
    public func enqueue(
        title: String,
        operation: @escaping @Sendable (JobContext) async throws -> Void
    ) -> UUID {
        let id = UUID()
        pending.append(PendingJob(id: id, title: title, operation: operation))
        outstanding.withLock { $0 += 1 }
        record(.init(id: id, title: title, state: .queued, startedAt: Date(), finishedAt: nil, errorText: nil))
        push(.init(id: id, title: title, state: .queued, progress: nil, message: nil, errorText: nil))
        pump()
        return id
    }

    public func cancel(jobID: UUID) {
        if let job = running[jobID] {
            job.task.cancel()
        } else if let idx = pending.firstIndex(where: { $0.id == jobID }) {
            let job = pending.remove(at: idx)
            finish(id: job.id, title: job.title, state: .cancelled, error: nil)
        }
    }

    public func cancelAll() {
        for (_, job) in running { job.task.cancel() }
        for job in pending { finish(id: job.id, title: job.title, state: .cancelled, error: nil) }
        pending.removeAll()
    }

    public var activeCount: Int { running.count }
    public var pendingCount: Int { pending.count }
    public var historyItems: [JobHistoryItem] { history }

    /// 订阅任务状态更新流（新订阅者会先收到最近 50 条状态用于恢复 UI）。
    public func updatesStream() -> AsyncStream<JobUpdate> {
        AsyncStream { (continuation: AsyncStream<JobUpdate>.Continuation) in
            let id = UUID()
            continuations[id] = continuation
            for update in recentUpdates.suffix(50) { continuation.yield(update) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    // MARK: - 内部

    private func pump() {
        while running.count < maxConcurrent, !pending.isEmpty {
            let job = pending.removeFirst()
            let task = Task<Void, Never> {
                await self.execute(job)
            }
            running[job.id] = RunningJob(task: task, title: job.title)
        }
    }

    private func execute(_ job: PendingJob) async {
        let context = JobContext(jobID: job.id) { [weak self] fraction, message in
            guard let self else { return }
            Task {
                await self.push(.init(id: job.id, title: job.title, state: .running, progress: fraction, message: message, errorText: nil))
            }
        }
        record(.init(id: job.id, title: job.title, state: .running, startedAt: Date(), finishedAt: nil, errorText: nil))
        push(.init(id: job.id, title: job.title, state: .running, progress: nil, message: nil, errorText: nil))
        do {
            try await job.operation(context)
            if Task.isCancelled {
                finish(id: job.id, title: job.title, state: .cancelled, error: nil)
            } else {
                finish(id: job.id, title: job.title, state: .finished, error: nil)
            }
        } catch is CancellationError {
            finish(id: job.id, title: job.title, state: .cancelled, error: nil)
        } catch {
            let text = String(describing: error)
            Log.error("任务失败 [\(job.title)]: \(text)", category: .core)
            finish(id: job.id, title: job.title, state: .failed, error: text)
        }
        running[job.id] = nil
        pump()
    }

    private func finish(id: UUID, title: String, state: JobState, error: String?) {
        outstanding.withLock { $0 = max(0, $0 - 1) }
        if let idx = history.firstIndex(where: { $0.id == id }) {
            let old = history[idx]
            history[idx] = .init(id: id, title: title, state: state, startedAt: old.startedAt, finishedAt: Date(), errorText: error)
        } else {
            history.append(.init(id: id, title: title, state: state, startedAt: Date(), finishedAt: Date(), errorText: error))
        }
        let progress: Double? = state == .finished ? 1 : nil
        push(.init(id: id, title: title, state: state, progress: progress, message: nil, errorText: error))
    }

    private func record(_ item: JobHistoryItem) {
        if let idx = history.firstIndex(where: { $0.id == item.id }) {
            history[idx] = item
        } else {
            history.append(item)
            if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        }
    }

    private func push(_ update: JobUpdate) {
        recentUpdates.append(update)
        if recentUpdates.count > 500 { recentUpdates.removeFirst(recentUpdates.count - 500) }
        for continuation in continuations.values { continuation.yield(update) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
