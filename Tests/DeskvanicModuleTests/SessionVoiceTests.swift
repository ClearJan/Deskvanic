import AppKit
import CoreGraphics
import Foundation
import Testing
import DeskvanicCore
@testable import DeskvanicSessionDock
@testable import DeskvanicVoice

@Suite("SessionDock")
struct SessionDockTests {
    @Test func workspaceStoreRoundtrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-dock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = Database(url: dir.appendingPathComponent("t.sqlite"))
        try await db.open()
        try await db.migrate(DeskvanicSchema.migrations)
        let store = WorkspaceStore(database: db)

        let workspace = LayoutEngine.Workspace(
            name: "写作",
            apps: ["com.apple.TextEdit"],
            windows: [
                LayoutEngine.WindowSnapshot(
                    appName: "TextEdit", bundleID: "com.apple.TextEdit",
                    windowTitle: "未命名", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                    displayID: "main"),
            ])
        var all = await store.load()
        all.append(workspace)
        await store.save(all)

        let loaded = await store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "写作")
        #expect(loaded[0].windows.first?.frame.width == 800)
    }

    @Test func displayIDForFrame() {
        // 主屏内坐标应返回 main
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let primaryHeight = primary.frame.height
        let cgFrame = CGRect(x: 100, y: primaryHeight - 500, width: 400, height: 300)
        #expect(LayoutEngine.displayID(for: cgFrame) == "main")
    }

    @Test func captureWindowsExcludesSelf() {
        // 当前测试进程无可见窗口；至少验证不崩溃且不含自身进程
        let windows = LayoutEngine.captureWindows()
        let ownPIDName = "swift"
        #expect(!windows.contains { $0.appName == ownPIDName })
    }
}

@Suite("VoiceDock")
struct VoiceDockTests {
    private func makeStore() async throws -> VoiceStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = Database(url: dir.appendingPathComponent("t.sqlite"))
        try await db.open()
        try await db.migrate(DeskvanicSchema.migrations + [VoiceSchema.migration])
        return VoiceStore(database: db)
    }

    @Test func memoStoreRoundtrip() async throws {
        let store = try await makeStore()
        await store.save(VoiceMemo(text: "会议纪要内容", audioPath: "/tmp/a.caf", locale: "zh-CN"))
        await store.save(VoiceMemo(text: "English note", audioPath: nil, locale: "en-US"))
        let all = await store.recent()
        #expect(all.count == 2)
        #expect(all.contains { $0.text == "会议纪要内容" && $0.locale == "zh-CN" })
    }

    @Test func userDictionaryReplacement() async {
        let engine = VoiceEngine()
        await engine.setUserDictionary(["deskvanic": "Deskvanic", "苹果机": "Mac"])
        let result = await engine.applyUserDictionary("我喜欢 deskvanic 和 苹果园，但 苹果机 最好")
        #expect(result.contains("Deskvanic"))
        #expect(result.contains("Mac"))
        #expect(!result.contains("苹果机"))
    }

    @Test func autoPunctuateAddsSentenceEnds() {
        let segments = [
            VoiceEngine.TranscriptSegment(text: "今天天气不错", timestamp: 0, isFinal: true),
            VoiceEngine.TranscriptSegment(text: "我们去爬山吧", timestamp: 8, isFinal: true),
            VoiceEngine.TranscriptSegment(text: "已经带问号？", timestamp: 16, isFinal: true),
        ]
        let result = VoiceEngine.autoPunctuate(segments)
        #expect(result == "今天天气不错。\n我们去爬山吧。\n已经带问号？")
    }

    @Test func onDeviceSupportQueryDoesNotCrash() async {
        // 真实查询（本机 zh-CN 应可用或不可用，均不得崩溃）
        let supports = await VoiceEngine.supportsOnDevice(locale: "zh-CN")
        _ = supports  // 仅验证可调用
    }
}

extension VoiceEngine {
    /// 测试辅助：设置用户词典。
    public func setUserDictionary(_ dictionary: [String: String]) {
        userDictionary = dictionary
    }
}
