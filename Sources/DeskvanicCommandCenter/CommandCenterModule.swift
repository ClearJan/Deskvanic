import Carbon.HIToolbox
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// Command Center 的工具入口：全局快捷键与授权目录管理。
public struct CommandCenterToolView: View {
    @State private var hotkeyText: String = ""
    @State private var hotkeyEnabled: Bool = true
    @State private var conflictMessage: String?
    @State private var folders: [String: String] = [:]   // key → path
    @State private var recordingHotkey = false
    @State private var pendingModifiers: UInt32 = 0
    @State private var pendingKeyCode: UInt32?

    public init() {}

    public var body: some View {
        ToolContainer("全局命令中心", subtitle: "Command Center · 快速查找与执行") {
            Form {
                Section("全局快捷键") {
                    HStack {
                        Text(hotkeyText)
                            .font(.title3.monospaced())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                        Toggle("启用", isOn: $hotkeyEnabled)
                            .onChange(of: hotkeyEnabled) { _, enabled in
                                applyHotkeySetting(enabled: enabled)
                            }
                        Spacer()
                        Button(recordingHotkey ? "按下新组合…" : "更改快捷键") {
                            recordingHotkey.toggle()
                        }
                        .disabled(!hotkeyEnabled)
                    }
                    if let conflictMessage {
                        Text(conflictMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("提示：面板内用 ↑↓ 选择、↩ 执行、Esc 关闭；\u{201C}>\u{201D} 前缀仅搜命令，\u{201C}app \u{201D} 前缀仅搜应用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("搜索范围（授权文件夹）") {
                    if folders.isEmpty {
                        Text("尚未授权任何文件夹。授权后命令面板可以搜索其中的文件。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(folders.sorted(by: { $0.value < $1.value }), id: \.key) { key, path in
                        HStack {
                            Image(systemName: "folder")
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("移除") { removeFolder(key: key) }
                        }
                    }
                    Button("添加授权文件夹…") { addFolder() }
                }

                Section("最近使用") {
                    RecentCommandsView()
                }
            }
            .formStyle(.grouped)
            .padding(20)
            .frame(minWidth: 560, minHeight: 520)
            .onAppear(perform: loadState)
            .onKeyPress(phases: .down) { keyPress in
                guard recordingHotkey else { return .ignored }
                return handleRecordingKey(keyPress)
            }
        }
    }

    // MARK: - 状态读写

    private func loadState() {
        let store = AppServices.settingsStore
        let settings = store.snapshot.commandCenter
        hotkeyEnabled = settings.hotkeyEnabled
        let hk = HotkeyManager.Hotkey(modifiers: settings.hotkeyModifiers, keyCode: settings.hotkeyKeyCode)
        hotkeyText = hk.displayText
        Task {
            var map: [String: String] = [:]
            let bookmarkStore = AppServices.bookmarkStore
            for key in await bookmarkStore.keys {
                if let url = await bookmarkStore.resolve(key: key) {
                    map[key] = url.path
                }
                await bookmarkStore.endAccess(key: key)
            }
            folders = map
        }
    }

    private func applyHotkeySetting(enabled: Bool) {
        let store = AppServices.settingsStore
        var snapshot = store.snapshot
        snapshot.commandCenter.hotkeyEnabled = enabled
        store.update { $0.commandCenter = snapshot.commandCenter }
        Task { @MainActor in
            await HotkeyCoordinator.shared.reapplyFromSettings()
        }
    }

    private func handleRecordingKey(_ keyPress: KeyPress) -> KeyPress.Result {
        // 记录修饰键 + 第一个非修饰键（Carbon 掩码）
        var modifiers: UInt32 = 0
        if keyPress.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if keyPress.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if keyPress.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if keyPress.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        pendingModifiers = modifiers

        // SwiftUI KeyPress 无 Carbon 键码，用字符反查虚拟键码表
        guard keyPress.modifiers.isEmpty == false,
              let character = keyPress.characters.first?.lowercased(),
              let keyCode = Self.carbonKeyCode(for: character) else { return .handled }
        pendingKeyCode = keyCode

        let newHotkey = HotkeyManager.Hotkey(modifiers: pendingModifiers, keyCode: keyCode)
        switch HotkeyManager.shared.register(newHotkey, owner: "命令面板", handler: {}) {
        case .success:
            recordingHotkey = false
            conflictMessage = nil
            let store = AppServices.settingsStore
            store.update {
                $0.commandCenter.hotkeyModifiers = pendingModifiers
                $0.commandCenter.hotkeyKeyCode = keyCode
            }
            hotkeyText = newHotkey.displayText
            Task { @MainActor in
                await HotkeyCoordinator.shared.reapplyFromSettings()
            }
        case .failure(let conflict):
            recordingHotkey = false
            switch conflict {
            case .occupied(let by, let hotkey):
                conflictMessage = "快捷键冲突：\(hotkey.displayText) 已被「\(by)」占用"
            case .registrationFailed(let underlying):
                conflictMessage = "注册失败：\(underlying)"
            }
        }
        return .handled
    }

    /// 字符 → Carbon 虚拟键码（覆盖字母/数字/常用键）。
    private static func carbonKeyCode(for character: String) -> UInt32? {
        let map: [String: UInt32] = [
            "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
            "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
            "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
            "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
            "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
            "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
            "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
            "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
            "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
            "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
            "9": UInt32(kVK_ANSI_9),
            " ": UInt32(kVK_Space), ".": UInt32(kVK_ANSI_Period), ",": UInt32(kVK_ANSI_Comma),
            "/": UInt32(kVK_ANSI_Slash), ";": UInt32(kVK_ANSI_Semicolon),
            "f1": UInt32(kVK_F1), "f2": UInt32(kVK_F2), "f3": UInt32(kVK_F3),
            "f4": UInt32(kVK_F4), "f5": UInt32(kVK_F5),
        ]
        return map[String(character)]
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择允许命令面板搜索的文件夹"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let key = "search-\(UUID().uuidString.prefix(8))"
            Task {
                try? await AppServices.bookmarkStore.saveBookmark(for: url, key: key)
                await FileSearcher.shared.invalidateCache()
                loadState()
            }
        }
    }

    private func removeFolder(key: String) {
        Task {
            await AppServices.bookmarkStore.removeBookmark(key: key)
            await FileSearcher.shared.invalidateCache()
            loadState()
        }
    }
}

struct RecentCommandsView: View {
    @State private var recents: [ScoredCommand] = []

    var body: some View {
        Group {
            if recents.isEmpty {
                Text("暂无使用记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recents.prefix(10)) { item in
                    HStack {
                        Image(systemName: item.command.icon)
                        Text(item.command.title).lineLimit(1)
                        Spacer()
                        Text(item.command.subtitle ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            recents = await CommandCenterEngine.shared.search(query: "")
        }
    }
}
