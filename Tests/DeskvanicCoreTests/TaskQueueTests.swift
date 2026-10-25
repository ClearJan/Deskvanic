import Foundation
import os
import Testing
@testable import DeskvanicCore

/// 测试辅助：跟踪当前值与历史峰值的线程安全计数器。
final class PeakCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0))

    var current: Int { lock.withLock { $0.current } }
    var peak: Int { lock.withLock { $0.peak } }

    func enter() {
        lock.withLock { state in
            state.current += 1
            state.peak = max(state.peak, state.current)
        }
    }

    func exit() {
        lock.withLock { $0.current -= 1 }
    }
}

/// 测试辅助：线程安全追加数组。
final class AtomicArray<T: Sendable>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [T]())

    var values: [T] { lock.withLock { $0 } }

    func append(_ item: T) {
        lock.withLock { $0.append(item) }
    }
}

@Suite("TaskQueue")
struct TaskQueueTests {

    @Test func executesJobsAndRecordsHistory() async throws {
        let queue = TaskQueue(name: "test-1", maxConcurrent: 2)
        let ran = AtomicArray<Int>()
        for i in 0..<5 {
            await queue.enqueue(title: "job-\(i)") { _ in
                ran.append(i)
            }
        }
        try await waitUntil(timeout: 3) {
            await queue.historyItems.filter { $0.state == .finished }.count == 5
        }
        #expect(ran.values.count == 5)
        let history = await queue.historyItems
        #expect(history.allSatisfy { $0.state == .finished && $0.finishedAt != nil })
        let active = await queue.activeCount
        let pending = await queue.pendingCount
        #expect(active == 0 && pending == 0)
    }

    @Test func respectsMaxConcurrency() async throws {
        let queue = TaskQueue(name: "test-2", maxConcurrent: 2)
        let gauge = PeakCounter()
        let start = Date()
        for _ in 0..<4 {
            await queue.enqueue(title: "sleep") { _ in
                gauge.enter()
                try await Task.sleep(nanoseconds: 150_000_000)
                gauge.exit()
            }
        }
        try await waitUntil(timeout: 5) {
            await queue.historyItems.filter { $0.state == .finished }.count == 4
        }
        #expect(gauge.peak <= 2)
        #expect(gauge.peak == 2)  // 并发上限确实被利用
        // 4 个 150ms 任务、并发 2 → 至少约 300ms
        #expect(Date().timeIntervalSince(start) >= 0.28)
    }

    @Test func cancelRunningJob() async throws {
        let queue = TaskQueue(name: "test-3", maxConcurrent: 1)
        let id = await queue.enqueue(title: "long") { _ in
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        await queue.cancel(jobID: id)
        try await waitUntil(timeout: 2) {
            await queue.historyItems.first { $0.id == id }?.state == .cancelled
        }
        let item = await queue.historyItems.first { $0.id == id }
        #expect(item?.state == .cancelled)
    }

    @Test func cancelQueuedJob() async throws {
        let queue = TaskQueue(name: "test-4", maxConcurrent: 1)
        // 占满并发
        _ = await queue.enqueue(title: "blocker") { _ in
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let queuedID = await queue.enqueue(title: "queued") { _ in }
        try await Task.sleep(nanoseconds: 50_000_000)
        await queue.cancel(jobID: queuedID)
        let item = await queue.historyItems.first { $0.id == queuedID }
        #expect(item?.state == .cancelled)
        // 阻塞任务释放后，被取消的任务不应再执行
        try await waitUntil(timeout: 3) {
            await queue.historyItems.filter { $0.state == .finished }.count == 1
        }
    }

    @Test func failureRecordedWithError() async throws {
        struct Boom: Error {}
        let queue = TaskQueue(name: "test-5", maxConcurrent: 1)
        let id = await queue.enqueue(title: "bad") { _ in
            throw Boom()
        }
        try await waitUntil(timeout: 2) {
            await queue.historyItems.first { $0.id == id }?.state == .failed
        }
        let item = await queue.historyItems.first { $0.id == id }
        #expect(item?.errorText?.contains("Boom") == true)
    }

    @Test func progressUpdatesStream() async throws {
        let queue = TaskQueue(name: "test-6", maxConcurrent: 1)
        let stream = await queue.updatesStream()
        let collector = UpdateCollector(stream: stream)
        let id = await queue.enqueue(title: "progress-job") { context in
            context.progress(0.5, "半程")
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        try await waitUntil(timeout: 2) {
            await queue.historyItems.first { $0.id == id }?.state == .finished
        }
        // 流式更新经 Task 异步投递，慢环境下可能晚于 history 就绪；轮询等待到账（限时 3s）
        try await waitUntil(timeout: 3) {
            let updates = await collector.updates
            return updates.contains { $0.id == id && $0.progress == 0.5 }
                && updates.contains { $0.id == id && $0.state == .finished && $0.progress == 1 }
        }
        let updates = await collector.updates
        let progressUpdate = updates.first { $0.id == id && $0.progress == 0.5 }
        #expect(progressUpdate?.message == "半程")
        #expect(updates.contains { $0.id == id && $0.state == .finished && $0.progress == 1 })
    }

    @Test func outstandingCounterTracksLifecycle() async throws {
        let queue = TaskQueue(name: "test-7", maxConcurrent: 1)
        _ = await queue.enqueue(title: "quick") { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = await queue.enqueue(title: "next") { _ in }
        // 排队 + 运行中合计 2
        #expect(queue.outstandingJobCount == 2)
        try await waitUntil(timeout: 3) {
            await queue.historyItems.filter { $0.state == .finished }.count == 2
        }
        #expect(queue.outstandingJobCount == 0)
    }

    // MARK: - 辅助

    private func waitUntil(
        timeout: TimeInterval,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let finalCheck = await condition()
        #expect(finalCheck, "等待条件超时")
    }
}

actor UpdateCollector {
    private(set) var updates: [TaskQueue.JobUpdate] = []

    init(stream: AsyncStream<TaskQueue.JobUpdate>) {
        let collector = ActorRef(self)
        Task {
            for await update in stream {
                await collector.actor.append(update)
            }
        }
    }

    func append(_ update: TaskQueue.JobUpdate) {
        updates.append(update)
    }
}

/// 帮助在非隔离 init 中捕获自身引用（测试辅助）。
private final class ActorRef<T: AnyObject>: @unchecked Sendable {
    let actor: T
    init(_ actor: T) { self.actor = actor }
}
