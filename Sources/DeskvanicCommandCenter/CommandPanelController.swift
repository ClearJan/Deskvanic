import AppKit
import DeskvanicCore
import SwiftUI

/// 全局命令面板控制器：管理浮动 NSPanel 的生命周期与显示/隐藏。
/// 面板为无边框浮动窗口，可成为关键窗口（键盘输入/输入法支持）。
@MainActor
public final class CommandPanelController: ObservableObject {
    public static let shared = CommandPanelController()

    private var panel: CommandPanel?
    public let model = CommandPanelModel()

    public init() {}

    public func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    public func showPanel() {
        let panel = panel ?? makePanel()
        position(panel)
        model.prepareForDisplay()
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    public func hidePanel() {
        panel?.orderOut(nil)
        model.panelHidden()
    }

    // MARK: - 内部

    private func makePanel() -> CommandPanel {
        let panel = CommandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = CommandPanelView(model: model)
            .environmentObject(self)
        panel.contentView = NSHostingView(rootView: view)
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.midX - panel.frame.width / 2
            let y = visible.maxY - visible.height * 0.18 - panel.frame.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

/// 自定义面板：允许成为关键窗口（无边框窗口默认不行）。
final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
