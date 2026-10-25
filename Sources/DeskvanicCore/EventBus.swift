import Foundation

/// 跨模块事件总线：发布-订阅 + AsyncStream，用于模块间松耦合通知
/// （例如"截图已保存 → 索引更新"、"工作流完成 → 通知中心"）。
/// 订阅可在任意执行上下文同步发起（内部以锁保护），发布经 actor 串行化。
public actor EventBus {
    public struct Event: Sendable, Hashable {
        public let topic: String
        public let data: [String: String]
        public init(_ topic: String, _ data: [String: String] = [:]) {
            self.topic = topic
            self.data = data
        }
    }

    public static let shared = EventBus()

    private let registry = ContinuationRegistry()

    public init() {}

    public func publish(_ event: Event) {
        registry.broadcast(event)
    }

    public func publish(_ topic: String, _ data: [String: String] = [:]) {
        publish(Event(topic, data))
    }

    /// 订阅事件流；topic 为 nil 时接收全部事件。流取消时自动清理注册项。
    nonisolated public func events(matching topic: String? = nil) -> AsyncStream<Event> {
        registry.subscribe(filter: topic)
    }

    public var subscriberCount: Int { registry.count }
}

private final class ContinuationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptions: [UUID: (filter: String?, continuation: AsyncStream<EventBus.Event>.Continuation)] = [:]

    func subscribe(filter: String?) -> AsyncStream<EventBus.Event> {
        let id = UUID()
        return AsyncStream { (continuation: AsyncStream<EventBus.Event>.Continuation) in
            lock.lock()
            subscriptions[id] = (filter, continuation)
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscriptions[id] = nil
                self.lock.unlock()
            }
        }
    }

    func broadcast(_ event: EventBus.Event) {
        lock.lock()
        let targets = subscriptions.values.filter { $0.filter == nil || $0.filter == event.topic }
        lock.unlock()
        for sub in targets {
            sub.continuation.yield(event)
        }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return subscriptions.count
    }
}

/// 常用事件主题，避免各模块硬编码字符串。
public enum EventTopics {
    public static let captureSaved = "capture.saved"
    public static let vaultItemAdded = "vault.item.added"
    public static let clipCaptured = "clip.captured"
    public static let jobUpdated = "job.updated"
    public static let flowRunFinished = "flow.run.finished"
    public static let settingsChanged = "settings.changed"
}
