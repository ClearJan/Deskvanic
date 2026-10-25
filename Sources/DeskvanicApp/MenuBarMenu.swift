import DeskvanicCore
import SwiftUI

/// 菜单栏下拉菜单：随模块落地逐步加入"快速截图 / 剪贴板 / 录音"等真实入口。
/// 只提供当前实际可用的操作，不保留空按钮。
struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button("打开 Deskvanic") {
                openWindow(id: AppWindows.main)
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("设置…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Divider()
            Button("退出 Deskvanic") {
                NSApp.terminate(nil)
            }
        }
    }
}
