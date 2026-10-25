import Foundation
import DeskvanicCore

/// 倒计时状态机：纯逻辑（时间由注入的 `now` 提供，测试确定性）。
public struct CountdownState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case idle, running, paused, finished
    }

    public var phase: Phase
    public var durationSeconds: Int
    /// 已运行的总秒数（不含暂停期间）。
    public var elapsedSeconds: Double
    /// 上次 tick 或启动时刻。
    public var lastTickAt: Date?

    public init(durationSeconds: Int) {
        self.phase = .idle
        self.durationSeconds = durationSeconds
        self.elapsedSeconds = 0
        self.lastTickAt = nil
    }

    public var remainingSeconds: Int {
        max(0, durationSeconds - Int(elapsedSeconds.rounded(.up)))
    }

    /// 开始/恢复。
    public mutating func start(at now: Date) {
        guard phase == .idle || phase == .paused else { return }
        phase = .running
        lastTickAt = now
    }

    /// 暂停。
    public mutating func pause() {
        guard phase == .running else { return }
        phase = .paused
        lastTickAt = nil
    }

    /// 复位。
    public mutating func reset() {
        phase = .idle
        elapsedSeconds = 0
        lastTickAt = nil
    }

    /// 推进：按当前时刻累计已运行时间。返回是否在本 tick 到达结束。
    @discardableResult
    public mutating func tick(at now: Date) -> Bool {
        guard phase == .running, let last = lastTickAt else { return false }
        elapsedSeconds += max(0, now.timeIntervalSince(last))
        lastTickAt = now
        if elapsedSeconds >= Double(durationSeconds) {
            phase = .finished
            return true
        }
        return false
    }
}

/// 番茄钟状态机：工作/休息循环。
public struct PomodoroState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case idle, work, breakTime, finished
    }

    public var phase: Phase
    public var workDurationSeconds: Int
    public var breakDurationSeconds: Int
    public var countdown: CountdownState
    /// 已完成的工作轮数。
    public var completedWorkSessions: Int
    /// 总轮数目标（0 = 不限）。
    public var targetSessions: Int

    public init(
        workMinutes: Int = 25, breakMinutes: Int = 5, targetSessions: Int = 0
    ) {
        self.phase = .idle
        self.workDurationSeconds = workMinutes * 60
        self.breakDurationSeconds = breakMinutes * 60
        self.countdown = CountdownState(durationSeconds: workMinutes * 60)
        self.completedWorkSessions = 0
        self.targetSessions = targetSessions
    }

    public mutating func start(at now: Date) {
        guard phase == .idle else { return }
        phase = .work
        countdown = CountdownState(durationSeconds: workDurationSeconds)
        countdown.start(at: now)
    }

    public mutating func pause(at now: Date) {
        countdown.tick(at: now)
        countdown.pause()
    }

    public mutating func resume(at now: Date) {
        countdown.start(at: now)
    }

    public mutating func reset() {
        phase = .idle
        completedWorkSessions = 0
        countdown = CountdownState(durationSeconds: workDurationSeconds)
    }

    /// 推进。返回事件：无 / 工作完成 / 休息完成 / 全部完成。
    public enum Event: Equatable, Sendable {
        case none, workFinished, breakFinished, allFinished
    }

    @discardableResult
    public mutating func tick(at now: Date) -> Event {
        guard phase == .work || phase == .breakTime else { return .none }
        let finished = countdown.tick(at: now)
        guard finished else { return .none }

        switch phase {
        case .work:
            completedWorkSessions += 1
            if targetSessions > 0 && completedWorkSessions >= targetSessions {
                phase = .finished
                return .allFinished
            }
            phase = .breakTime
            countdown = CountdownState(durationSeconds: breakDurationSeconds)
            countdown.start(at: now)
            return .workFinished
        case .breakTime:
            phase = .work
            countdown = CountdownState(durationSeconds: workDurationSeconds)
            countdown.start(at: now)
            return .breakFinished
        default:
            return .none
        }
    }

    public var remainingSeconds: Int { countdown.remainingSeconds }
}
