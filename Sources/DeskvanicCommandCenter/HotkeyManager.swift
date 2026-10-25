import AppKit
import Carbon.HIToolbox
import Foundation
import DeskvanicCore

/// 全局快捷键管理：基于 Carbon RegisterEventHotKey（macOS 公开 API）。
/// 支持冲突检测：同一 (modifiers, keyCode) 组合只能注册一次，重复注册返回错误。
public final class HotkeyManager: @unchecked Sendable {
    public static let shared = HotkeyManager()

    public struct Hotkey: Hashable, Sendable {
        public let modifiers: UInt32   // Carbon 修饰键掩码
        public let keyCode: UInt32     // Carbon 虚拟键码
        public init(modifiers: UInt32, keyCode: UInt32) {
            self.modifiers = modifiers
            self.keyCode = keyCode
        }

        /// 可读描述，如 "⇧⌘Z"
        public var displayText: String {
            var text = ""
            if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
            if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
            if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
            if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
            text += Self.keyToString(keyCode) ?? "Key\(keyCode)"
            return text
        }

        static func keyToString(_ code: UInt32) -> String? {
            switch Int(code) {
            case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
            case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
            case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
            case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
            case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
            case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
            case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
            case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
            case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
            case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
            case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
            case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
            case kVK_ANSI_9: return "9"
            case kVK_Space: return "Space"; case kVK_Return: return "↩"; case kVK_Escape: return "⎋"
            case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
            case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
            case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
            case kVK_ANSI_KeypadEnter: return "Keypad↩"
            case kVK_ANSI_Period: return "."; case kVK_ANSI_Comma: return ","
            default: return nil
            }
        }
    }

    private struct Registration {
        let ref: EventHotKeyRef
        let hotkey: Hotkey
        let owner: String
        var handler: (@MainActor @Sendable () -> Void)?
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private let lock = NSLock()
    private var eventHandlerInstalled = false

    public init() {}

    /// 注册全局快捷键；组合已被占用时返回 false 并给出占用者描述。
    @discardableResult
    public func register(
        _ hotkey: Hotkey,
        owner: String,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> Result<Void, HotkeyConflict> {
        lock.lock(); defer { lock.unlock() }

        installEventHandlerIfNeeded()

        for registration in registrations.values where registration.hotkey == hotkey {
            return .failure(.occupied(by: registration.owner, hotkey: hotkey))
        }

        var ref: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: Self.signature, id: nextID)
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers, hotkeyID,
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            return .failure(.registrationFailed(underlying: "RegisterEventHotKey 返回 \(status)"))
        }
        registrations[nextID] = Registration(ref: ref, hotkey: hotkey, owner: owner, handler: handler)
        nextID += 1
        Log.info("全局快捷键已注册 [\(hotkey.displayText)] → \(owner)", category: .command)
        return .success(())
    }

    /// 注销指定组合。
    public func unregister(_ hotkey: Hotkey) {
        lock.lock(); defer { lock.unlock() }
        for (id, registration) in registrations where registration.hotkey == hotkey {
            UnregisterEventHotKey(registration.ref)
            registrations[id] = nil
        }
    }

    public func unregisterAll() {
        lock.lock(); defer { lock.unlock() }
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    public var activeHotkeys: [Hotkey] {
        lock.lock(); defer { lock.unlock() }
        return registrations.values.map(\.hotkey)
    }

    // MARK: - Carbon 事件分发

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // EventHandlerUPP 需要 C 函数指针；通过上下文箱回调到 self。
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            guard status == noErr else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handleHotkeyPressed(id: hotkeyID.id)
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func handleHotkeyPressed(id: UInt32) {
        lock.lock()
        let handler = registrations[id]?.handler
        lock.unlock()
        guard let handler else { return }
        Task { @MainActor in
            handler()
        }
    }

    /// 热键签名 'ODSK'（Deskvanic）：用于事件回调中识别本应用注册的热键。
    static let signature: OSType = 0x4F_44_53_4B
}

public enum HotkeyConflict: Error, Sendable {
    /// 组合已被其他功能占用（by = 占用者名称）。
    case occupied(by: String, hotkey: HotkeyManager.Hotkey)
    /// 系统注册失败（如保留组合）。
    case registrationFailed(underlying: String)
}
