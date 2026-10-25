import Foundation

/// Deskvanic 统一错误模型：每个错误都附带用户可读的解释与可行的恢复建议。
public struct DeskvanicError: Error, Codable, Sendable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        case invalidInput
        case fileNotFound
        case fileUnreadable
        case fileWriteFailed
        case unsupportedFormat
        case diskSpaceInsufficient
        case permissionDenied
        case cancelled
        case timeout
        case databaseFailure
        case indexCorrupted
        case outputValidationFailed
        case networkFailure
        case pairingFailed
        case externalService
        case internalInconsistency
    }

    public let code: Code
    public let message: String
    public let recoverySuggestion: String
    public let underlying: String?

    public init(
        _ code: Code,
        _ message: String,
        recovery: String = "请重试；若持续失败请查看日志（帮助 → 打开日志目录）。",
        underlying: String? = nil
    ) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recovery
        self.underlying = underlying
    }

    public var description: String {
        var text = "[Deskvanic.\(code.rawValue)] \(message)"
        if let underlying { text += " (\(underlying))" }
        return text
    }

    public static func cancellation() -> DeskvanicError {
        DeskvanicError(.cancelled, "操作已取消", recovery: "")
    }
}

extension Error {
    /// 将任意错误规范化为 DeskvanicError，保留底层描述用于日志。
    public func asDeskvanicError() -> DeskvanicError {
        self as? DeskvanicError
            ?? DeskvanicError(
                .externalService,
                String(describing: self),
                recovery: "请重试或查看日志以了解详情。"
            )
    }
}
