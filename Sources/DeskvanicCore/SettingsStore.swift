import Foundation

/// 用户设置存储：Codable 快照 + 原子写入 + 变更事件。
/// 通过不可变快照读取，避免 UI 与后台任务共享可变状态。
public final class SettingsStore<T: Codable & Equatable & Sendable>: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var cached: T
    private var debouncedWriteTask: Task<Void, Never>?

    public init(defaults: T, url: URL) {
        self.url = url
        self.cached = Self.load(from: url) ?? defaults
    }

    public var snapshot: T {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// 更新设置：立即更新内存快照，防抖写入磁盘，并发布事件到总线。
    public func update(_ mutate: (inout T) -> Void) {
        let newValue: T
        let oldValue: T
        lock.lock()
        oldValue = cached
        var copy = cached
        mutate(&copy)
        cached = copy
        newValue = copy
        lock.unlock()

        guard newValue != oldValue else { return }
        schedulePersist(newValue)
        Task { await EventBus.shared.publish(EventTopics.settingsChanged, ["target": "\(T.self)"]) }
    }

    public func reloadFromDisk() {
        lock.lock()
        if let loaded = Self.load(from: url) { cached = loaded }
        lock.unlock()
    }

    // MARK: - 内部

    private func schedulePersist(_ value: T) {
        debouncedWriteTask?.cancel()
        debouncedWriteTask = Task { [url] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(value)
                try AtomicFileWriter.write(data: data, to: url)
            } catch {
                Log.error("设置写入失败: \(String(describing: error))", category: .core)
            }
        }
    }

    private static func load(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.error("设置解析失败，使用默认值: \(String(describing: error))", category: .core)
            return nil
        }
    }
}

/// 全局应用设置模型：各模块的设置分组存放在这里，保持单一存储文件与版本化迁移的可能。
public struct AppSettings: Codable, Equatable, Sendable {
    public struct CommandCenterSettings: Codable, Equatable, Sendable {
        public var hotkeyEnabled: Bool
        public var hotkeyModifiers: UInt32   // Carbon modifier mask
        public var hotkeyKeyCode: UInt32     // Carbon virtual key code
        public var maxRecentItems: Int
        public init(
            hotkeyEnabled: Bool = true,
            hotkeyModifiers: UInt32 = 4608,  // cmd+shift
            hotkeyKeyCode: UInt32 = 6,       // Z
            maxRecentItems: Int = 20
        ) {
            self.hotkeyEnabled = hotkeyEnabled
            self.hotkeyModifiers = hotkeyModifiers
            self.hotkeyKeyCode = hotkeyKeyCode
            self.maxRecentItems = maxRecentItems
        }
    }

    public struct ClipVaultSettings: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var maxItems: Int
        public var retentionDays: Int
        public var excludedBundleIDs: [String]
        public var pauseMonitoring: Bool
        public init(
            enabled: Bool = true,
            maxItems: Int = 500,
            retentionDays: Int = 30,
            excludedBundleIDs: [String] = [],
            pauseMonitoring: Bool = false
        ) {
            self.enabled = enabled
            self.maxItems = maxItems
            self.retentionDays = retentionDays
            self.excludedBundleIDs = excludedBundleIDs
            self.pauseMonitoring = pauseMonitoring
        }
    }

    public struct CaptureSettings: Codable, Equatable, Sendable {
        public var saveToDisk: Bool
        public var playSound: Bool
        public var ocrLanguage: String
        public init(saveToDisk: Bool = true, playSound: Bool = true, ocrLanguage: String = "zh-Hans") {
            self.saveToDisk = saveToDisk
            self.playSound = playSound
            self.ocrLanguage = ocrLanguage
        }
    }

    public struct GeneralSettings: Codable, Equatable, Sendable {
        public var language: String  // "system" | "zh-Hans" | "en"
        public var launchAtLogin: Bool
        public var keepInMenuBar: Bool
        public init(language: String = "system", launchAtLogin: Bool = false, keepInMenuBar: Bool = true) {
            self.language = language
            self.launchAtLogin = launchAtLogin
            self.keepInMenuBar = keepInMenuBar
        }
    }

    public var settingsVersion: Int
    public var general: GeneralSettings
    public var commandCenter: CommandCenterSettings
    public var clipVault: ClipVaultSettings
    public var capture: CaptureSettings

    public init() {
        settingsVersion = 1
        general = GeneralSettings()
        commandCenter = CommandCenterSettings()
        clipVault = ClipVaultSettings()
        capture = CaptureSettings()
    }
}
