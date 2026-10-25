import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import Speech
import UserNotifications

/// 系统权限中心：统一探测、请求与状态展示。
/// 所有需要系统授权的功能必须先经过这里，权限被拒绝时给出可理解的指引而不是静默失败。
public enum PermissionKind: String, Codable, Sendable, CaseIterable {
    case screenCapture
    case microphone
    case speechRecognition
    case accessibility
    case notifications
    case localNetwork

    public var displayName: String {
        switch self {
        case .screenCapture: return "屏幕录制"
        case .microphone: return "麦克风"
        case .speechRecognition: return "语音识别"
        case .accessibility: return "辅助功能"
        case .notifications: return "通知"
        case .localNetwork: return "本地网络"
        }
    }
}

public enum PermissionStatus: String, Codable, Sendable {
    case granted, denied, notDetermined, restricted
}

public enum Permissions {
    /// 只读探测当前状态，不弹系统对话框。
    public static func status(of kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .screenCapture:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            return switch AVAudioApplication.shared.recordPermission {
            case .granted: .granted
            case .denied: .denied
            case .undetermined: .notDetermined
            @unknown default: .restricted
            }
        case .speechRecognition:
            return switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: .granted
            case .denied: .denied
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            @unknown default: .restricted
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: .granted
            case .denied: .denied
            case .notDetermined: .notDetermined
            @unknown default: .restricted
            }
        case .localNetwork:
            // 本地网络无同步探测 API；未实际使用前视为未确定，由 NearLink 首次广播后生效。
            return .notDetermined
        }
    }

    /// 发起请求（会弹系统对话框）。返回最终状态。
    @discardableResult
    public static func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .screenCapture:
            _ = CGRequestScreenCaptureAccess()
            return await status(of: kind)
        case .microphone:
            let granted: Bool = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .granted : .denied
        case .speechRecognition:
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume(returning: ())
                }
            }
            return await status(of: kind)
        case .accessibility:
            // 辅助功能只能引导用户到系统设置开启。
            // kAXTrustedCheckOptionPrompt 在 Swift 6 下为非并发安全的 C 全局变量，此处使用其常量值。
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return await status(of: kind)
        case .notifications:
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            return await status(of: kind)
        case .localNetwork:
            // 首次 Bonjour 广播时系统会自动弹出本地网络授权。
            return .notDetermined
        }
    }

    /// 系统设置中对应面板的 URL（用于"去设置"按钮）。
    public static func systemSettingsURL(for kind: PermissionKind) -> URL? {
        switch kind {
        case .screenCapture:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .speechRecognition:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        case .localNetwork:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        }
    }
}
