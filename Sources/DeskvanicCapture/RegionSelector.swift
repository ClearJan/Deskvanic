import AppKit
import Foundation

/// 区域选择覆盖层：全屏透明面板 + 十字光标，拖拽框选，Esc 取消。
/// 选择完成经回调返回屏幕坐标（左上原点，点单位）。
@MainActor
public final class RegionSelector: NSObject {
    public static let shared = RegionSelector()

    private var panels: [NSScreen: SelectionPanel] = [:]
    private var completion: ((CGRect?) -> Void)?
    private var finished = false

    /// 开始区域选择。用户完成（松开鼠标）回调所选矩形，Esc 取消回调 nil。
    public func begin(completion: @escaping @MainActor (CGRect?) -> Void) {
        guard panels.isEmpty else {
            completion(nil)
            return
        }
        self.completion = completion
        self.finished = false

        for screen in NSScreen.screens {
            let panel = SelectionPanel(screen: screen, selector: self)
            panel.makeKeyAndOrderFront(nil)
            panels[screen] = panel
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    fileprivate func finish(with rect: CGRect?) {
        guard !finished else { return }
        finished = true
        closePanels()
        completion?(rect)
        completion = nil
    }

    private func closePanels() {
        for (_, panel) in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }
}

/// 单屏选择面板。
final class SelectionPanel: NSPanel {
    private let selectionView: SelectionView

    init(screen: NSScreen, selector: RegionSelector) {
        selectionView = SelectionView(frame: screen.frame, selector: selector)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        self.contentView = selectionView
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        // Esc 取消
        selectionView.finish(with: nil)
    }
}

/// 拖拽选择视图：暗色遮罩 + 亮区。
final class SelectionView: NSView {
    private weak var selector: RegionSelector?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    init(frame: NSRect, selector: RegionSelector) {
        self.selector = selector
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart, let end = dragCurrent else {
            selector?.finish(with: nil)
            return
        }
        let rect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y))
        dragStart = nil
        dragCurrent = nil
        if rect.width < 8 || rect.height < 8 {
            selector?.finish(with: nil)  // 过小视为取消
        } else {
            // 转换为 AppKit 全局坐标（主屏左下原点），由 CaptureEngine 内部再转 CG 坐标
            let global = CGRect(
                x: rect.minX + frame.minX,
                y: rect.minY + frame.minY,
                width: rect.width, height: rect.height)
            selector?.finish(with: global)
        }
    }

    func finish(with rect: CGRect?) {
        selector?.finish(with: rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        if let start = dragStart, let end = dragCurrent {
            let rect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y))
            // 挖亮选择区域
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            NSColor.clear.setFill()
            rect.fill(using: .clear)

            NSColor.white.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}
