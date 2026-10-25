import AVFoundation
import AppKit
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// Media Studio 主界面。
public struct MediaStudioView: View {
    @State private var sourceURL: URL?
    @State private var mediaInfo: MediaEngine.MediaInfo?
    @State private var waveform: [Double] = []
    @State private var startSeconds = 0.0
    @State private var endSeconds = 0.0
    @State private var gifFPS = 8
    @State private var gifMaxPixel = 480
    @State private var statusMessage: String?
    @State private var audioFormat: MediaEngine.AudioFormat = .m4a
    @State private var outputDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    @State private var player: AVPlayer?

    public init() {}

    public var body: some View {
        ToolContainer("媒体处理", subtitle: "Media Studio · 裁剪 · 提取 · 转换 · GIF") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button("选择音/视频文件…") { pickFile() }
                    if let sourceURL {
                        Text(sourceURL.lastPathComponent).font(.callout)
                    }
                    Spacer()
                    if let info = mediaInfo {
                        Text(String(format: "%.1fs · %@", info.durationSeconds,
                                    info.hasVideo ? "视频" : "音频"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let sourceURL, let info = mediaInfo {
                    previewPane(url: sourceURL, info: info)
                    trimSection
                    conversionSection
                    gifSection
                } else {
                    ContentUnavailableView("选择媒体文件", systemImage: "waveform.badge.plus",
                                           description: Text("支持系统编解码器覆盖的常见格式（mp4/mov/m4a/wav 等）。"))
                }

                if let message = statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func previewPane(url: URL, info: MediaEngine.MediaInfo) -> some View {
        GroupBox("预览") {
            VStack(alignment: .leading, spacing: 8) {
                if info.hasVideo {
                    VideoPlayerContainer(url: url)
                        .frame(height: 240)
                }
                if info.hasAudio {
                    WaveformView(peaks: waveform)
                        .frame(height: 60)
                }
                HStack {
                    Button("播放开头") {
                        player = AVPlayer(url: url)
                        player?.play()
                    }
                    Button("停止") { player?.pause() }
                    Text("输出目录：\(outputDir.lastPathComponent)")
                        .font(.caption).foregroundStyle(.tertiary)
                    Button("更改…") { chooseOutputDir() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var trimSection: some View {
        GroupBox("裁剪") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(String(format: "开始 %.1fs", startSeconds))
                        .font(.caption.monospacedDigit())
                        .frame(width: 90)
                    Slider(value: $startSeconds, in: 0...max(0.1, (endSeconds == 0 ? mediaInfo?.durationSeconds ?? 1 : endSeconds) - 0.1))
                    Button("设为起点") { startSeconds = 0 }
                }
                HStack {
                    Text(String(format: "结束 %.1fs", endSeconds))
                        .font(.caption.monospacedDigit())
                        .frame(width: 90)
                    Slider(value: $endSeconds, in: startSeconds + 0.1...(mediaInfo?.durationSeconds ?? 1))
                    if endSeconds == 0 {
                        Button("设为结尾") { endSeconds = mediaInfo?.durationSeconds ?? 0 }
                    }
                }
                Button("裁剪并导出") { Task { await trim() } }
                    .disabled(endSeconds <= startSeconds)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var conversionSection: some View {
        GroupBox("转换与提取") {
            HStack(spacing: 12) {
                Picker("音频格式", selection: $audioFormat) {
                    ForEach(MediaEngine.AudioFormat.allCases, id: \.self) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .frame(width: 110)
                if mediaInfo?.hasAudio == true {
                    Button("转换为 \(audioFormat.rawValue.uppercased())") { Task { await convert() } }
                }
                if mediaInfo?.hasVideo == true, mediaInfo?.hasAudio == true {
                    Button("提取音频（m4a）") { Task { await extractAudio() } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var gifSection: some View {
        GroupBox("视频转 GIF") {
            VStack(alignment: .leading, spacing: 8) {
                if mediaInfo?.hasVideo != true {
                    Text("需要视频文件").font(.caption).foregroundStyle(.tertiary)
                }
                HStack {
                    Stepper("帧率 \(gifFPS) fps", value: $gifFPS, in: 1...20)
                        .frame(width: 180)
                    Stepper("最长边 \(gifMaxPixel)px", value: $gifMaxPixel, in: 120...1280, step: 40)
                        .frame(width: 220)
                    Button("从当前裁剪范围生成 GIF") { Task { await makeGIF() } }
                        .disabled(mediaInfo?.hasVideo != true || endSeconds <= startSeconds)
                }
                Text("GIF 为逐帧量化编码，体积可能较大；建议 5 秒内片段。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - 动作

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let info = try await MediaEngine.inspect(url: url)
                    mediaInfo = info
                    sourceURL = url
                    startSeconds = 0
                    endSeconds = info.durationSeconds
                    if info.hasAudio, info.hasVideo == false {
                        waveform = (try? MediaEngine.waveform(url: url)) ?? []
                    }
                    statusMessage = nil
                } catch {
                    statusMessage = "无法读取媒体：\(String(describing: error))"
                }
            }
        }
    }

    private func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                outputDir = url
            }
        }
    }

    private func trim() async {
        guard let sourceURL else { return }
        let start = startSeconds
        let end = endSeconds
        let dir = outputDir
        statusMessage = "裁剪中…"
        await TaskQueue.shared.enqueue(title: "裁剪：\(sourceURL.lastPathComponent)") { _ in
            let output = try await MediaEngine.trim(
                source: sourceURL, start: start, end: end, destinationDirectory: dir)
            await MainActor.run {
                statusMessage = "裁剪完成：\(output.lastPathComponent)（输出已校验）"
                NSWorkspace.shared.activateFileViewerSelecting([output])
            }
        }
    }

    private func convert() async {
        guard let sourceURL else { return }
        let format = audioFormat
        let dir = outputDir
        statusMessage = "转换中…"
        await TaskQueue.shared.enqueue(title: "音频转换 → \(format.rawValue.uppercased())") { _ in
            let output = try await MediaEngine.convertAudio(
                source: sourceURL, to: format, destinationDirectory: dir)
            await MainActor.run {
                statusMessage = "转换完成：\(output.lastPathComponent)"
            }
        }
    }

    private func extractAudio() async {
        guard let sourceURL else { return }
        let dir = outputDir
        await TaskQueue.shared.enqueue(title: "提取音频：\(sourceURL.lastPathComponent)") { _ in
            let output = try await MediaEngine.extractAudio(source: sourceURL, destinationDirectory: dir)
            await MainActor.run { statusMessage = "已提取：\(output.lastPathComponent)" }
        }
    }

    private func makeGIF() async {
        guard let sourceURL else { return }
        let start = startSeconds
        let duration = min(endSeconds - startSeconds, 60)
        let fps = gifFPS
        let maxPixel = gifMaxPixel
        let dir = outputDir
        await TaskQueue.shared.enqueue(title: "生成 GIF（\(Int(duration))s @\(fps)fps）") { _ in
            let output = try await MediaEngine.generateGIF(
                source: sourceURL, start: start, duration: duration,
                framesPerSecond: fps, maxPixel: maxPixel, destinationDirectory: dir)
            await MainActor.run {
                statusMessage = "GIF 已生成：\(output.lastPathComponent)"
            }
        }
    }
}

/// 波形显示。
struct WaveformView: View {
    let peaks: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            ForEach(Array(peaks.enumerated()), id: \.offset) { _, peak in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 3, height: max(2, peak * 52))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// AVPlayer 包装。
struct VideoPlayerContainer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    class AVPlayerView: NSView {
        var player: AVPlayer? {
            didSet { playerLayer.player = player }
        }
        private let playerLayer = AVPlayerLayer()

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(playerLayer)
            playerLayer.videoGravity = .resizeAspect
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
    }
}
