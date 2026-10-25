import DeskvanicCommandCenter
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

@main
struct DeskvanicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel.shared

    var body: some Scene {
        WindowGroup(id: AppWindows.main) {
            MainWindow()
                .environmentObject(appModel)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}   // 单窗口产品，去掉"新建"菜单
            CommandMenu("工具") {
                Button("命令面板…") {
                    CommandPanelController.shared.togglePanel()
                }
                Divider()
                ForEach(ToolRegistry.shared.entries) { tool in
                    Button(tool.name) {
                        NotificationCenter.default.post(
                            name: .deskvanicOpenTool, object: nil, userInfo: ["tool": tool.id])
                    }
                }
            }
        }

        MenuBarExtra {
            MenuBarMenu()
        } label: {
            Image(systemName: "square.grid.2x2.fill")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            GeneralSettingsView()
                .environmentObject(appModel)
        }
    }
}

enum AppWindows {
    static let main = "main"
}

/// 应用代理：管理激活策略与生命周期日志。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("应用已启动", category: .app)
        Task { await AppModel.shared.boot() }
        Task { @MainActor in
            await HotkeyCoordinator.shared.reapplyFromSettings()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let taskCount = TaskQueue.shared.outstandingJobCount
        guard taskCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "还有 \(taskCount) 个任务正在执行"
        alert.informativeText = "现在退出将中断正在执行的任务。已完成的输出不受影响。"
        alert.addButton(withTitle: "继续并退出")
        alert.addButton(withTitle: "取消")
        let choice = alert.runModal()
        return choice == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
