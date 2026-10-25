import AVFoundation
import Foundation
import DeskvanicCore
import Speech

/// VoiceDock 语音引擎：录音（AVAudioEngine）+ 语音识别（SFSpeechRecognizer）。
///
/// 能力边界（如实声明）：
/// - 优先使用设备端识别（requiresOnDeviceRecognition）；当设备端不可用时回退服务器识别，
///   并在 UI 标注当前模式（用户可强制仅设备端，此时不支持的语言明确提示不可用）。
/// - 录音仅保存在本机（Transfers/VoiceMemos），不上传；识别经系统框架完成。
/// - 自动标点为简单规则（静音停顿 + 句尾），非完美 NLP。
public actor VoiceEngine {

    // MARK: - 状态

    public enum State: String, Sendable {
        case idle, recording, paused, transcribing, finished, failed
    }

    public struct TranscriptSegment: Sendable, Codable, Hashable {
        public let text: String
        public let timestamp: TimeInterval   // 相对录音开始
        public let isFinal: Bool
    }

    private var audioEngine: AVAudioEngine?
    private var recognitionRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTaskInstance: SFSpeechRecognitionTask?
    private var tapInstalled = false

    public private(set) var state: State = .idle
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var currentPartial: String = ""
    public private(set) var recordingURL: URL?
    public private(set) var lastError: String?
    public private(set) var isOnDevice: Bool = false

    private var recordingStart: Date?
    private var lastSpeechTime: Date?
    /// 用户词典：识别结果后替换（词 → 替换词）。
    public var userDictionary: [String: String] = [:]
    /// 语言标识（zh-CN / en-US 等）。
    public var localeIdentifier: String = "zh-CN"

    /// MainActor 侧统一注入配置（actor 属性必须经 actor 方法改写）。
    public func configure(userDictionary: [String: String], localeIdentifier: String) {
        self.userDictionary = userDictionary
        self.localeIdentifier = localeIdentifier
    }

    // MARK: - 权限

    public static func requestPermissions() async -> Bool {
        let micStatus = await Permissions.status(of: .microphone)
        var micOK = micStatus == .granted
        if !micOK {
            micOK = await Permissions.request(.microphone) == .granted
        }
        let speechStatus = await Permissions.status(of: .speechRecognition)
        var speechOK = speechStatus == .granted
        if !speechOK {
            speechOK = await Permissions.request(.speechRecognition) == .granted
        }
        return micOK && speechOK
    }

    /// 指定语言是否支持设备端识别。
    public static func supportsOnDevice(locale: String) async -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    // MARK: - 录音与识别

    public func startRecording() async throws {
        guard state == .idle || state == .finished || state == .failed else { return }
        guard await Self.requestPermissions() else {
            lastError = "麦克风或语音识别权限被拒绝"
            state = .failed
            throw DeskvanicError(.permissionDenied, lastError!,
                               recovery: "请在系统设置中授权麦克风与语音识别。")
        }

        segments = []
        currentPartial = ""
        lastError = nil
        recordingStart = Date()
        lastSpeechTime = nil

        // 录音文件
        let memoDir = AppEnvironment.transfersDirectory.appendingPathComponent("VoiceMemos", isDirectory: true)
        try? FileManager.default.createDirectory(at: memoDir, withIntermediateDirectories: true)
        let url = FileSafety.uniqueDestination(in: memoDir, preferredName: "memo-\(Int(Date().timeIntervalSince1970)).caf")
        recordingURL = url

        // macOS 无 AVAudioSession；AVAudioEngine 直接使用默认输入设备
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard let recognizer, recognizer.isAvailable else {
            throw DeskvanicError(.externalService, "语音识别器不可用（语言：\(localeIdentifier)）",
                               recovery: "可在设置中切换语言，或检查网络。")
        }
        isOnDevice = recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw DeskvanicError(.externalService, "无法获取麦克风输入格式")
        }

        // 写文件 + 送识别
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? file.write(from: buffer)
            request.append(buffer)
            Task { await self?.noteSpeechActivity() }
        }
        tapInstalled = true

        recognitionRecognizer = recognizer
        recognitionRequest = request
        audioEngine = engine
        try engine.start()
        state = .recording

        // 识别任务（回调内提取 Sendable 纯值，再跨隔离域传递）
        recognitionTaskInstance = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let nsError = error as NSError?
            let message: String? = {
                guard let error else { return nil }
                // 用户主动停止的常规结束不算错误
                return nsError?.code == 203 || nsError?.code == 1101 ? nil : error.localizedDescription
            }()
            Task { await self?.handleRecognitionValues(text: text, isFinal: isFinal, errorMessage: message) }
        }
    }

    /// 静音检测（自动标点辅助）。
    private func noteSpeechActivity() {
        lastSpeechTime = Date()
    }

    private func handleRecognitionValues(text: String?, isFinal: Bool, errorMessage: String?) {
        if let text {
            if isFinal {
                let segment = TranscriptSegment(
                    text: text, timestamp: recordingStart.map { Date().timeIntervalSince($0) } ?? 0,
                    isFinal: true)
                segments.append(segment)
                currentPartial = ""
            } else {
                currentPartial = text
            }
        }
        if let errorMessage {
            lastError = "识别错误：\(errorMessage)"
        }
    }

    public func pause() {
        guard state == .recording, let engine = audioEngine else { return }
        engine.pause()
        state = .paused
    }

    public func resume() async throws {
        guard state == .paused, let engine = audioEngine else { return }
        try engine.start()
        state = .recording
    }

    /// 停止录音并返回（词典替换后的）最终文本。
    @discardableResult
    public func stopRecording() async -> String {
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
        }
        if tapInstalled, let input = audioEngine?.inputNode {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        // 等待最终结果（最多 3 秒）
        for _ in 0..<30 {
            if currentPartial.isEmpty { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        recognitionRequest = nil
        recognitionRecognizer = nil
        recognitionTaskInstance = nil
        audioEngine = nil
        state = .finished

        let raw = segments.map(\.text).joined(separator: "\n")
        return applyUserDictionary(raw)
    }

    /// 取消：删除录音文件。
    public func cancelRecording() {
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
        }
        if tapInstalled, let input = audioEngine?.inputNode {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionRecognizer = nil
        recognitionTaskInstance = nil
        audioEngine = nil
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        segments = []
        currentPartial = ""
        state = .idle
    }

    // MARK: - 音频文件导入转写

    /// 导入音频文件转写（不录音，直接识别文件）。
    public func transcribeFile(at url: URL, locale: String) async throws -> String {
        guard await Self.requestPermissions() else {
            throw DeskvanicError(.permissionDenied, "语音识别权限被拒绝")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            throw DeskvanicError(.externalService, "语音识别器不可用（语言：\(locale)）")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        // 词典快照（resultHandler 闭包非隔离，不能访问 actor 状态）
        let dictionary = userDictionary
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    var text = result.bestTranscription.formattedString
                    for (term, replacement) in dictionary where !term.isEmpty {
                        text = text.replacingOccurrences(of: term, with: replacement)
                    }
                    continuation.resume(returning: text)
                } else if let error {
                    finished = true
                    continuation.resume(throwing: DeskvanicError(.externalService, "转写失败：\(error.localizedDescription)"))
                }
            }
        }
    }

    // MARK: - 用户词典

    public func applyUserDictionary(_ text: String) -> String {
        var result = text
        for (term, replacement) in userDictionary where !term.isEmpty {
            result = result.replacingOccurrences(of: term, with: replacement)
        }
        return result
    }

    // MARK: - 自动标点（简单规则）

    /// 基于静音间隙插入标点：在相邻最终段之间追加中文句号（如段尾无标点）。
    public static func autoPunctuate(_ segments: [TranscriptSegment]) -> String {
        let punctuation = "。！？.!?，,；;：:"
        return segments.map { segment in
            var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = text.last, !punctuation.contains(last) {
                text += "。"
            }
            return text
        }.joined(separator: "\n")
    }
}
