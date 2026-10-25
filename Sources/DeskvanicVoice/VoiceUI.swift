import AppKit
import AVFoundation
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// VoiceDock 主界面：录音、转写、历史、词典、插入到前台应用。
public struct VoiceDockView: View {
    @State private var engine = VoiceEngine()
    @State private var state: VoiceEngine.State = .idle
    @State private var partialText = ""
    @State private var finalText = ""
    @State private var isOnDevice = false
    @State private var localeIdentifier = "zh-CN"
    @State private var onDeviceSupported = false
    @State private var forceOnDevice = false
    @State private var memoURL: URL?
    @State private var statusMessage: String?
    @State private var history: [VoiceMemo] = []
    @State private var dictionaryText = ""
    @State private var pollTimer: Timer?

    public init() {}

    public var body: some View {
        ToolContainer("语音输入", subtitle: "VoiceDock · 录音 → 转写 → 编辑 → 插入") {
            VStack(alignment: .leading, spacing: 16) {
                controls
                transcript
                dictionarySection
                historySection
                if let message = statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                capabilityNote
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            onDeviceSupported = await VoiceEngine.supportsOnDevice(locale: localeIdentifier)
            await reloadHistory()
        }
        .onDisappear { pollTimer?.invalidate() }
    }

    // MARK: - 控制区

    private var controls: some View {
        GroupBox("录音与识别") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    // 状态指示
                    Circle()
                        .fill(stateColor)
                        .frame(width: 14, height: 14)
                        .opacity(state == .recording ? 1 : 0.5)
                        .symbolEffect(.pulse, isActive: state == .recording)
                    Text(stateLabel).font(.headline)
                    Spacer()
                    Picker("语言", selection: Binding(
                        get: { localeIdentifier },
                        set: { newValue in
                            localeIdentifier = newValue
                            Task { onDeviceSupported = await VoiceEngine.supportsOnDevice(locale: newValue) }
                        })) {
                        Text("中文（普通话）").tag("zh-CN")
                        Text("English (US)").tag("en-US")
                        Text("中文（粤语）").tag("zh-HK")
                    }
                    .frame(width: 160)
                }

                HStack(spacing: 10) {
                    if state == .recording {
                        Button("暂停") { Task { await engine.pause(); await syncState() } }
                        Button("停止并转写") { Task { await stopAndCollect() } }
                        Button("取消", role: .destructive) {
                            Task {
                                await engine.cancelRecording()
                                finalText = ""
                                partialText = ""
                                await syncState()
                            }
                        }
                    } else if state == .paused {
                        Button("继续") { Task { try? await engine.resume(); await syncState() } }
                        Button("停止并转写") { Task { await stopAndCollect() } }
                    } else {
                        Button {
                            Task { await startRecording() }
                        } label: {
                            Label("开始录音", systemImage: "mic.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("导入音频文件转写…") { importAudio() }
                    }
                }
                HStack {
                    Toggle("仅设备端识别（不上传音频）", isOn: $forceOnDevice)
                        .disabled(!onDeviceSupported)
                    Text(onDeviceSupported
                         ? (isOnDevice ? "当前支持设备端识别" : "当前使用服务器识别")
                         : "该语言不支持设备端识别（将使用服务器识别或不可用）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var transcript: some View {
        GroupBox("转写结果") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $finalText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                if !partialText.isEmpty {
                    Text("识别中：\(partialText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack {
                    Button("复制文本") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(finalText, forType: .string)
                    }
                    .disabled(finalText.isEmpty)
                    Button("插入到前台应用") { insertToFrontmost() }
                        .disabled(finalText.isEmpty)
                    Button("保存为文本") { saveAsText() }
                        .disabled(finalText.isEmpty)
                    Spacer()
                    if let memoURL {
                        Button("播放录音") { play(url: memoURL) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var dictionarySection: some View {
        GroupBox("用户词典（识别结果自动替换）") {
            VStack(alignment: .leading, spacing: 8) {
                Text("格式：每行一条，`词条=替换为`")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("例如：deskvanic=Deskvanic", text: $dictionaryText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("应用词典到当前文本") {
                        finalText = parseDictionary().reduce(finalText) { text, pair in
                            text.replacingOccurrences(of: pair.0, with: pair.1)
                        }
                    }
                    .disabled(finalText.isEmpty || dictionaryText.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var historySection: some View {
        GroupBox("转写历史") {
            VStack(alignment: .leading, spacing: 6) {
                if history.isEmpty {
                    Text("暂无历史记录").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(history) { memo in
                    HStack {
                        Image(systemName: "waveform")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memo.text.isEmpty ? "（空）" : String(memo.text.prefix(60)))
                                .font(.caption).lineLimit(1)
                            Text(memo.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(memo.text, forType: .string)
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var capabilityNote: some View {
        Text("说明：识别优先使用设备端能力；不支持的语种将明确标注，不会静默上传。录音仅保存在本机。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - 状态

    private var stateColor: Color {
        switch state {
        case .idle: return .gray
        case .recording: return .red
        case .paused: return .orange
        case .transcribing: return .blue
        case .finished: return .green
        case .failed: return .red
        }
    }

    private var stateLabel: String {
        switch state {
        case .idle: return "就绪"
        case .recording: return "录音中…"
        case .paused: return "已暂停"
        case .transcribing: return "转写中…"
        case .finished: return "完成"
        case .failed: return "失败"
        }
    }

    // MARK: - 动作

    private func startRecording() async {
        do {
            // 词典注入
            engine.userDictionary = Dictionary(parseDictionary(), uniquingKeysWith: { _, new in new })
            engine.localeIdentifier = forceOnDevice ? localeIdentifier : localeIdentifier
            try await engine.startRecording()
            await syncState()
            // 轮询部分结果
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                Task { await syncState() }
            }
        } catch {
            statusMessage = "无法开始录音：\(String(describing: error))"
            await syncState()
        }
    }

    private func stopAndCollect() async {
        pollTimer?.invalidate()
        state = .transcribing
        _ = await engine.stopRecording()
        let segments = await engine.segments
        // 有最终段时做自动标点；否则保持空（用户可在编辑框自行输入）
        finalText = segments.isEmpty ? "" : VoiceEngine.autoPunctuate(segments)
        memoURL = await engine.recordingURL
        isOnDevice = await engine.isOnDevice
        await syncState()
        await saveMemo()
    }

    private func syncState() async {
        state = await engine.state
        partialText = await engine.currentPartial
    }

    private func saveMemo() async {
        guard !finalText.isEmpty else { return }
        let memo = VoiceMemo(
            text: finalText, audioPath: memoURL?.path, locale: localeIdentifier)
        await VoiceServices.store.save(memo)
        await reloadHistory()
    }

    private func reloadHistory() async {
        history = await VoiceServices.store.recent()
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "选择要转写的音频文件"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                state = .transcribing
                do {
                    finalText = try await engine.transcribeFile(at: url, locale: localeIdentifier)
                    memoURL = url
                    state = .finished
                    await saveMemo()
                } catch {
                    statusMessage = "转写失败：\(String(describing: error))"
                    state = .failed
                }
            }
        }
    }

    private func insertToFrontmost() {
        Task {
            let status = await Permissions.status(of: .accessibility)
            guard status == .granted else {
                _ = await Permissions.request(.accessibility)
                statusMessage = "模拟输入需要辅助功能权限；文本已复制，可 ⌘V 粘贴。"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(finalText, forType: .string)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finalText, forType: .string)
            let source = CGEventSource(stateID: .combinedSessionState)
            let vKey: CGKeyCode = 9
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
            down?.flags = [.maskCommand]
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
            up?.flags = [.maskCommand]
            down?.post(tap: .cghidEventTap)
            usleep(30_000)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func saveAsText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "voice-memo.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? finalText.data(using: .utf8)?.write(to: url, options: .atomic)
            statusMessage = "已保存：\(url.lastPathComponent)"
        }
    }

    private func play(url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.play()
        // 保留引用到播放结束（简化：静态数组）
        Self.activePlayers.append(player)
        if Self.activePlayers.count > 4 { Self.activePlayers.removeFirst() }
    }

    private static var activePlayers: [AVAudioPlayer] = []

    private func parseDictionary() -> [(String, String)] {
        dictionaryText.components(separatedBy: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]).trimmingCharacters(in: .whitespaces),
                    String(parts[1]).trimmingCharacters(in: .whitespaces))
        }
    }
}

/// 转写历史条目。
public struct VoiceMemo: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let text: String
    public let audioPath: String?
    public let locale: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, text: String, audioPath: String?, locale: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.audioPath = audioPath
        self.locale = locale
        self.createdAt = createdAt
    }
}

public actor VoiceStore {
    private let db: Database

    public init(database: Database) {
        self.db = database
    }

    public func save(_ memo: VoiceMemo) async {
        _ = try? await db.runUpdate(
            "INSERT OR REPLACE INTO voice_memos(id, text, audio_path, locale, created_at) VALUES(?,?,?,?,?)",
            [.text(memo.id), .text(memo.text), memo.audioPath.map { .text($0) } ?? .null,
             .text(memo.locale), .text(DateCodec.encode(memo.createdAt))])
    }

    public func recent(limit: Int = 100) async -> [VoiceMemo] {
        let rows = (try? await db.run(
            "SELECT id, text, audio_path, locale, created_at FROM voice_memos ORDER BY created_at DESC LIMIT ?",
            [.int(Int64(limit))])) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.stringValue,
                  let text = row["text"]?.stringValue else { return nil }
            return VoiceMemo(
                id: id, text: text, audioPath: row["audio_path"]?.stringValue,
                locale: row["locale"]?.stringValue ?? "zh-CN",
                createdAt: DateCodec.decode(row["created_at"]?.stringValue ?? "") ?? Date())
        }
    }
}

/// VoiceDock 数据库迁移（版本 8）。
public enum VoiceSchema {
    public static let migration = DBMigration(version: 8, name: "voice-dock", statements: [
        """
        CREATE TABLE voice_memos(
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            audio_path TEXT,
            locale TEXT NOT NULL DEFAULT 'zh-CN',
            created_at TEXT NOT NULL
        )
        """,
        "CREATE INDEX idx_voice_created ON voice_memos(created_at DESC)",
    ])
}

/// VoiceDock 服务装配点。
@MainActor
public enum VoiceServices {
    public static var store = VoiceStore(database: Database(url: AppEnvironment.databaseURL))

    public static func inject(store newStore: VoiceStore) {
        store = newStore
    }
}
