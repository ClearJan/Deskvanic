import AppKit
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// Capture Studio 主界面：截图入口、历史、OCR 与标注。
public struct CaptureToolView: View {
    @State private var records: [CaptureRecord] = []
    @State private var selected: CaptureRecord?
    @State private var statusMessage: String?
    @State private var windows: [CaptureEngine.WindowInfo] = []
    @State private var showWindowPicker = false
    @State private var annotateImage: NSImage?
    @State private var annotateRecord: CaptureRecord?
    @State private var ocrText: String = ""
    @State private var ocrRunning = false

    public init() {}

    public var body: some View {
        ToolContainer("截图与识别", subtitle: "Capture Studio · 截图 · OCR · 标注") {
            VStack(spacing: 0) {
                toolbar
                if let message = statusMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HSplitView {
                    historyList.frame(minWidth: 260, idealWidth: 300)
                    detailPane.frame(minWidth: 420)
                }
            }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
        }
        .sheet(isPresented: $showWindowPicker) { windowPickerSheet }
        .sheet(item: $annotateRecord) { record in
            AnnotationEditorView(record: record, initialImage: annotateImage) { result in
                Task { await handleAnnotated(result, record: record) }
            }
        }
    }

    // MARK: - 工具栏

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                startRegionCapture()
            } label: {
                Label("区域截图", systemImage: "viewfinder")
            }
            .keyboardShortcut("1", modifiers: [.command, .shift])

            Button {
                Task { await loadWindows(); showWindowPicker = true }
            } label: {
                Label("窗口截图", systemImage: "macwindow")
            }

            Button {
                startFullScreenCapture()
            } label: {
                Label("全屏截图", systemImage: "rectangle.inset.filled")
            }

            Spacer()

            if let record = selected {
                Button("重新识别") { Task { await runOCR(for: record) } }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        Divider()
    }

    // MARK: - 历史列表

    private var historyList: some View {
        List(records, selection: Binding(
            get: { selected?.id },
            set: { id in
                selected = records.first { $0.id == id }
                ocrText = selected?.ocrText ?? ""
            })) { record in
            CaptureRow(record: record)
                .contextMenu {
                    Button("删除", role: .destructive) {
                        Task {
                            try? await CaptureServices.store.delete(id: record.id)
                            await reload()
                        }
                    }
                }
        }
        .listStyle(.sidebar)
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(
                    "暂无截图", systemImage: "camera.viewfinder",
                    description: Text("用上方按钮开始第一次截图。截图会自动保存到本地并建立索引。"))
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let record = selected {
            CaptureDetail(
                record: record,
                ocrText: $ocrText,
                ocrRunning: ocrRunning,
                onCopyImage: { copyImage(record) },
                onCopyText: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ocrText, forType: .string)
                    statusMessage = "已复制识别文本"
                },
                onSave: { saveAs(record) },
                onAnnotate: { openAnnotate(record) },
                onPin: { pin(record) })
        } else {
            ContentUnavailableView("选择一条记录", systemImage: "photo.on.rectangle")
        }
    }

    // MARK: - 动作

    private func startRegionCapture() {
        guard CaptureEngine.hasScreenPermission() else {
            CaptureEngine.requestScreenPermission()
            statusMessage = "需要屏幕录制权限：请在系统设置 → 隐私与安全性 → 屏幕录制 中允许 Deskvanic，然后重试。"
            return
        }
        RegionSelector.shared.begin { rect in
            guard let rect else { return }
            guard let image = CaptureEngine.captureRegion(appKitRect: rect) else {
                statusMessage = "区域截图失败（权限或显示环境变化）"
                return
            }
            Task { await store(image: image, kind: "region") }
        }
    }

    private func startFullScreenCapture() {
        guard CaptureEngine.hasScreenPermission() else {
            CaptureEngine.requestScreenPermission()
            statusMessage = "需要屏幕录制权限（见上方提示）。"
            return
        }
        guard let image = CaptureEngine.captureFullScreen() else {
            statusMessage = "全屏截图失败"
            return
        }
        Task { await store(image: image, kind: "fullscreen") }
    }

    private func loadWindows() async {
        windows = CaptureEngine.listWindows()
    }

    private var windowPickerSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择窗口").font(.headline)
            if windows.isEmpty {
                Text("未发现可见窗口（可能缺少屏幕录制权限）")
                    .foregroundStyle(.secondary)
            }
            List(windows) { window in
                Button {
                    showWindowPicker = false
                    capture(window: window)
                } label: {
                    HStack {
                        Image(systemName: "macwindow.on.rectangle")
                        VStack(alignment: .leading) {
                            Text(window.title.isEmpty ? window.ownerName : window.title)
                            Text(window.ownerName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(height: 320)
            HStack {
                Spacer()
                Button("取消") { showWindowPicker = false }
            }
        }
        .padding(18)
        .frame(width: 480)
    }

    private func capture(window: CaptureEngine.WindowInfo) {
        guard let image = CaptureEngine.captureWindow(id: window.id) else {
            statusMessage = "窗口截图失败"
            return
        }
        Task { await store(image: image, kind: "window") }
    }

    private func store(image: CGImage, kind: String) async {
        do {
            let url = try CaptureEngine.savePNG(image, to: CaptureServices.capturesDirectory)
            let record = CaptureRecord(filePath: url.path, kind: kind)
            try await CaptureServices.store.add(record)
            selected = record
            await reload()
            statusMessage = "截图已保存"
            await runOCR(for: record)
        } catch {
            statusMessage = "保存失败：\(String(describing: error))"
        }
    }

    private func runOCR(for record: CaptureRecord) async {
        guard let image = NSImage(contentsOfFile: record.filePath)?.cgImage(
            forProposedRect: nil, context: nil, hints: nil) else { return }
        ocrRunning = true
        defer { ocrRunning = false }
        do {
            let result = try await OCREngine.recognizeText(in: image)
            let barcodes = try await OCREngine.detectBarcodes(in: image)
            ocrText = result.fullText
            try await CaptureServices.store.updateOCR(id: record.id, ocrText: result.fullText, barcodes: barcodes)
            if !barcodes.isEmpty {
                statusMessage = "识别到 \(barcodes.count) 个条码：\(barcodes.joined(separator: "、"))"
            }
            await reload()
        } catch {
            statusMessage = "OCR 失败：\(String(describing: error))"
        }
    }

    private func copyImage(_ record: CaptureRecord) {
        guard let image = NSImage(contentsOfFile: record.filePath) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        statusMessage = "已复制截图"
    }

    private func saveAs(_ record: CaptureRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (record.filePath as NSString).lastPathComponent
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: record.filePath))
                try data.write(to: dest, options: .atomic)
                statusMessage = "已保存到 \(dest.lastPathComponent)"
            } catch {
                statusMessage = "导出失败：\(String(describing: error))"
            }
        }
    }

    private func openAnnotate(_ record: CaptureRecord) {
        guard let image = NSImage(contentsOfFile: record.filePath) else { return }
        annotateImage = image
        annotateRecord = record
    }

    private func handleAnnotated(_ image: NSImage, record: CaptureRecord) async {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        await store(image: cg, kind: "annotated")
    }

    private func pin(_ record: CaptureRecord) {
        PinWindowManager.shared.pin(imagePath: record.filePath)
    }

    private func reload() async {
        records = (try? await CaptureServices.store.recent()) ?? []
        if let selected, !records.contains(where: { $0.id == selected.id }) {
            self.selected = nil
        }
    }
}

struct CaptureRow: View {
    let record: CaptureRecord

    var body: some View {
        HStack(spacing: 10) {
            if let image = NSImage(contentsOfFile: record.filePath) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 36)
                    .clipped()
                    .cornerRadius(4)
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .frame(width: 52, height: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(kindLabel).font(.callout)
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var kindLabel: String {
        switch record.kind {
        case "region": return "区域截图"
        case "window": return "窗口截图"
        case "fullscreen": return "全屏截图"
        case "annotated": return "标注后"
        default: return "导入"
        }
    }
}

struct CaptureDetail: View {
    let record: CaptureRecord
    @Binding var ocrText: String
    let ocrRunning: Bool
    let onCopyImage: () -> Void
    let onCopyText: () -> Void
    let onSave: () -> Void
    let onAnnotate: () -> Void
    let onPin: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let image = NSImage(contentsOfFile: record.filePath) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 380)
                        .frame(maxWidth: .infinity)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Label("图片文件缺失", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("复制图片", action: onCopyImage)
                    Button("标注…", action: onAnnotate)
                    Button("固定悬浮", action: onPin)
                    Button("导出…", action: onSave)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("识别文本（本机 OCR）").font(.headline)
                        if ocrRunning {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        if !ocrText.isEmpty {
                            Button("复制文本", action: onCopyText)
                        }
                    }
                    if ocrText.isEmpty {
                        Text("尚无识别结果。点击「重新识别」可对本图运行 OCR。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        TextEditor(text: $ocrText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 160)
                            .scrollContentBackground(.hidden)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !record.barcodePayloads.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("条码内容").font(.headline)
                            ForEach(record.barcodePayloads, id: \.self) { payload in
                                Text(payload)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}
