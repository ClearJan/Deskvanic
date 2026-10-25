import AppKit
import Foundation
import DeskvanicCore

/// 模块级服务定位：由应用组合根（AppModel）在启动时注入共享实例，
/// 未注入时使用默认真实实现，保证模块可独立运行与测试。
@MainActor
public enum AppServices {
    /// 共享设置存储（与主应用同一实例，由 AppModel 注入）。
    public static var settingsStore: SettingsStore<AppSettings> = SettingsStore(
        defaults: AppSettings(), url: AppEnvironment.settingsURL)

    /// 共享书签存储。
    public nonisolated static let bookmarkStore = BookmarkStore()
}

/// 快捷键协调器：读取设置并统一注册/注销命令面板快捷键。
/// 冲突时如实报告，不静默失败。
@MainActor
public final class HotkeyCoordinator: ObservableObject {
    public static let shared = HotkeyCoordinator()

    @Published public private(set) var activeHotkeyText: String?
    @Published public private(set) var conflictText: String?

    private let panelController: CommandPanelController

    public init(panelController: CommandPanelController = .shared) {
        self.panelController = panelController
    }

    /// 应用当前设置中的快捷键配置。
    public func reapplyFromSettings() async {
        let settings = AppServices.settingsStore.snapshot.commandCenter
        // 先清掉我们注册的所有快捷键
        HotkeyManager.shared.unregisterAll()

        guard settings.hotkeyEnabled else {
            activeHotkeyText = nil
            conflictText = nil
            return
        }

        let hotkey = HotkeyManager.Hotkey(
            modifiers: settings.hotkeyModifiers,
            keyCode: settings.hotkeyKeyCode)
        switch HotkeyManager.shared.register(hotkey, owner: "命令面板") { [panelController] in
            panelController.togglePanel()
        } {
        case .success:
            activeHotkeyText = hotkey.displayText
            conflictText = nil
        case .failure(let conflict):
            activeHotkeyText = nil
            switch conflict {
            case .registrationFailed(let underlying):
                conflictText = "注册失败：\(underlying)"
            case .occupied(let by, let hotkey):
                conflictText = "快捷键 \(hotkey.displayText) 已被「\(by)」占用，请在设置中更换"
            }
            Log.warning("快捷键注册冲突: \(String(describing: conflict))", category: .command)
        }
    }
}
