import AppKit
import DeskvanicCore
import SwiftUI

/// 标注编辑器：裁剪、矩形、箭头、文字、真像素模糊。
/// 每步操作生成新图像叠加（原图不动），完成时回调结果。
struct AnnotationEditorView: View {
    let record: CaptureRecord
    let initialImage: NSImage?
    let onComplete: (NSImage) -> Void

    enum Tool: String, CaseIterable {
        case crop = "裁剪"
        case rect = "矩形"
        case arrow = "箭头"
        case text = "文字"
        case blur = "模糊"
    }

    @Environment(\.dismiss) private var dismiss
    @State private var currentImage: NSImage?
    @State private var tool: Tool = .rect
    @State private var colorIndex = 0
    @State private var textInput = ""
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var imageSize: CGSize = .zero

    private let colors: [Color] = [.red, .yellow, .green, .blue, .white]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                canvas
                    .background(.black.opacity(0.35))
                Divider()
                sidePanel
                    .frame(width: 230)
            }
        }
        .frame(minWidth: 780, minHeight: 580)
        .onAppear {
            currentImage = initialImage
            imageSize = currentImage?.size ?? .zero
        }
    }

    private var header: some View {
        HStack {
            Text("标注编辑").font(.headline)
            Text((record.filePath as NSString).lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
            Spacer()
            Button("还原") { currentImage = initialImage }
            Button("完成") {
                if let currentImage {
                    onComplete(currentImage)
                }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            Button("取消") { dismiss() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let image = currentImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                }
                if let start = dragStart, let end = dragEnd {
                    let rect = CGRect(
                        x: min(start.x, end.x), y: min(start.y, end.y),
                        width: abs(end.x - start.x), height: abs(end.y - start.y))
                    Rectangle()
                        .stroke(borderColor, lineWidth: 2)
                        .background(tool == .blur ? Color.yellow.opacity(0.15) : Color.clear)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(displayedSize: geo.size))
            .onTapGesture { location in
                if tool == .text {
                    applyText(at: location, displayedSize: geo.size)
                }
            }
        }
        .padding(10)
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("工具", selection: $tool) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    Text(tool.rawValue).tag(tool)
                }
            }
            .pickerStyle(.inline)

            HStack {
                Text("颜色")
                ForEach(colors.indices, id: \.self) { index in
                    Circle()
                        .fill(colors[index])
                        .frame(width: 20, height: 20)
                        .overlay {
                            if colorIndex == index {
                                Circle().strokeBorder(.primary, lineWidth: 2)
                            }
                        }
                        .onTapGesture { colorIndex = index }
                }
            }

            if tool == .text {
                TextField("输入文字后点击画布", text: $textInput)
                    .textFieldStyle(.roundedBorder)
            }

            switch tool {
            case .crop:
                Text("拖拽框选后松开，仅保留选区。")
                    .font(.caption).foregroundStyle(.secondary)
            case .blur:
                Text("拖拽选区松开即应用。模糊为真像素破坏处理，应用后该区域不可恢复。")
                    .font(.caption).foregroundStyle(.secondary)
            case .rect, .arrow:
                Text("拖拽绘制。")
                    .font(.caption).foregroundStyle(.secondary)
            case .text:
                Text("先输入文字，再点击画布放置。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
    }

    private var borderColor: Color {
        tool == .blur ? .yellow : colors[colorIndex]
    }

    // MARK: - 手势与操作

    private func dragGesture(displayedSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil { dragStart = value.startLocation }
                dragEnd = value.location
            }
            .onEnded { value in
                defer { dragStart = nil; dragEnd = nil }
                guard let start = dragStart else { return }
                switch tool {
                case .crop:
                    applyCrop(viewStart: start, viewEnd: value.location, displayedSize: displayedSize)
                case .rect:
                    applyRect(viewStart: start, viewEnd: value.location, displayedSize: displayedSize)
                case .arrow:
                    applyArrow(viewStart: start, viewEnd: value.location, displayedSize: displayedSize)
                case .blur:
                    applyBlur(viewStart: start, viewEnd: value.location, displayedSize: displayedSize)
                case .text:
                    break
                }
            }
    }

    /// 视图坐标 → 图像像素坐标（图像 fit 居中显示）。
    private func toPixel(_ point: CGPoint, displayedSize: CGSize) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0,
              displayedSize.width > 0, displayedSize.height > 0 else { return nil }
        let scale = min(displayedSize.width / imageSize.width, displayedSize.height / imageSize.height)
        let drawnSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let offsetX = (displayedSize.width - drawnSize.width) / 2
        let offsetY = (displayedSize.height - drawnSize.height) / 2
        let xInImage = (point.x - offsetX) / scale
        let yInImage = (point.y - offsetY) / scale
        guard xInImage >= 0, yInImage >= 0,
              xInImage <= imageSize.width, yInImage <= imageSize.height else { return nil }
        return CGPoint(x: xInImage, y: yInImage)
    }

    private func applyCG(_ newImage: CGImage) {
        currentImage = NSImage(cgImage: newImage, size: CGSize(width: newImage.width, height: newImage.height))
        imageSize = currentImage?.size ?? .zero
    }

    private func cgColor() -> CGColor {
        NSColor(colors[colorIndex]).cgColor
    }

    /// NSImage 像素坐标（左上原点，随 imageSize 同步像素尺寸）→ CG 像素坐标（左下原点）。
    private func cgY(_ y: CGFloat, height: CGFloat) -> CGFloat { height - y }

    private func applyCrop(viewStart: CGPoint, viewEnd: CGPoint, displayedSize: CGSize) {
        guard let currentImage,
              let cg = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let s = toPixel(viewStart, displayedSize: displayedSize),
              let e = toPixel(viewEnd, displayedSize: displayedSize) else { return }
        let rect = CGRect(
            x: min(s.x, e.x), y: min(s.y, e.y),
            width: abs(e.x - s.x), height: abs(e.y - s.y))
        if let cropped = AnnotationEngine.crop(cg, rect: rect) {
            applyCG(cropped)
        }
    }

    private func applyRect(viewStart: CGPoint, viewEnd: CGPoint, displayedSize: CGSize) {
        guard let currentImage,
              let cg = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let s = toPixel(viewStart, displayedSize: displayedSize),
              let e = toPixel(viewEnd, displayedSize: displayedSize) else { return }
        let h = CGFloat(cg.height)
        let rect = CGRect(
            x: min(s.x, e.x), y: cgY(max(s.y, e.y), height: h),
            width: abs(e.x - s.x), height: abs(e.y - s.y))
        if let result = AnnotationEngine.drawRect(cg, rect: rect, color: cgColor()) {
            applyCG(result)
        }
    }

    private func applyArrow(viewStart: CGPoint, viewEnd: CGPoint, displayedSize: CGSize) {
        guard let currentImage,
              let cg = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let s = toPixel(viewStart, displayedSize: displayedSize),
              let e = toPixel(viewEnd, displayedSize: displayedSize) else { return }
        let h = CGFloat(cg.height)
        if let result = AnnotationEngine.drawArrow(
            cg,
            start: CGPoint(x: s.x, y: cgY(s.y, height: h)),
            end: CGPoint(x: e.x, y: cgY(e.y, height: h)),
            color: cgColor()) {
            applyCG(result)
        }
    }

    private func applyBlur(viewStart: CGPoint, viewEnd: CGPoint, displayedSize: CGSize) {
        guard let currentImage,
              let cg = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let s = toPixel(viewStart, displayedSize: displayedSize),
              let e = toPixel(viewEnd, displayedSize: displayedSize) else { return }
        let rect = CGRect(
            x: min(s.x, e.x), y: min(s.y, e.y),
            width: abs(e.x - s.x), height: abs(e.y - s.y))
        if let result = AnnotationEngine.blurRegion(cg, rect: rect, radius: 16) {
            applyCG(result)
        }
    }

    private func applyText(at viewPoint: CGPoint, displayedSize: CGSize) {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let currentImage,
              let cg = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pixel = toPixel(viewPoint, displayedSize: displayedSize) else { return }
        if let result = AnnotationEngine.drawText(cg, text: text, at: pixel, color: cgColor()) {
            applyCG(result)
            textInput = ""
        }
    }
}

/// 固定截图悬浮窗管理：双击关闭。
@MainActor
final class PinWindowManager {
    static let shared = PinWindowManager()

    private var windows: [NSPanel] = []

    func pin(imagePath: String) {
        guard let image = NSImage(contentsOfFile: imagePath) else { return }
        let maxSize: CGFloat = 360
        var size = image.size
        let scale = min(1, maxSize / max(size.width, size.height))
        size.width *= scale
        size.height *= scale

        let panel = PinPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView = imageView

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - 40 - CGFloat(windows.count % 5) * 24,
                y: visible.maxY - size.height - 60 - CGFloat((windows.count / 5) % 3) * 24))
        }
        panel.orderFrontRegardless()
        panel.onDoubleClick { [weak panel] in
            panel?.orderOut(nil)
        }
        windows.append(panel)
    }
}

/// 双击关闭的图片悬浮窗。
final class PinPanel: NSPanel {
    private var doubleClickHandler: (() -> Void)?

    override var canBecomeKey: Bool { false }

    func onDoubleClick(_ handler: @escaping () -> Void) {
        doubleClickHandler = handler
        let gesture = NSClickGestureRecognizer(
            target: self,
            action: #selector(handleClick(_:)))
        gesture.numberOfClicksRequired = 2
        contentView?.addGestureRecognizer(gesture)
    }

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        doubleClickHandler?()
    }
}
