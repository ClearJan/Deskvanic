import Foundation
import DeskvanicCore

/// 设置类型别名（核心层 AppSettings 的嵌套配置）。
public typealias ClipVaultSettings = AppSettings.ClipVaultSettings

/// ClipVault 服务装配点：由应用组合根在启动时注入共享实例与设置闭包；
/// 未注入时模块用自身默认实现（真实数据库 + 默认设置），保证可独立运行。
/// 整体 MainActor 隔离：监控器与 UI 都在主线程访问。
@MainActor
public enum ClipVaultServices {
    /// 共享 ClipStore（AppModel.boot 时注入同一数据库实例）。
    public static var store = makeDefaultStore()

    /// 共享监控器（懒创建，读取注入的设置闭包）。
    public static var monitor: ClipboardMonitor = ClipboardMonitor(
        store: store,
        settings: { ClipVaultSettings() })

    /// 由组合根注入共享数据库、索引与设置读取闭包（在应用启动时调用一次）。
    public static func inject(
        store newStore: ClipStore,
        settings: @escaping () -> ClipVaultSettings
    ) {
        store = newStore
        monitor = ClipboardMonitor(store: newStore, settings: settings)
        persistPauseState = { paused in
            settingsStore.update { $0.clipVault.pauseMonitoring = paused }
        }
    }

    /// 暂停状态持久化回调（由组合根在注入时设置；默认空实现）。
    public static var persistPauseState: (Bool) -> Void = { _ in }
    /// 设置写入器（由组合根注入；默认写独立文件不影响主设置）。
    public static var settingsStore: SettingsStore<AppSettings> = SettingsStore(
        defaults: AppSettings(),
        url: AppEnvironment.supportDirectory.appendingPathComponent("ClipVaultSettings.json"))

    private static func makeDefaultStore() -> ClipStore {
        let db = Database(url: AppEnvironment.databaseURL)
        let index = SearchIndex(database: db)
        return ClipStore(database: db, index: index)
    }
}
