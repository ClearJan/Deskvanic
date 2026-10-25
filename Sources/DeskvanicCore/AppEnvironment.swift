import Foundation

/// 全局路径约定：所有 Deskvanic 托管数据集中存放，便于备份、审计与卸载。
public enum AppEnvironment {
    public static let appName = "Deskvanic"
    public static let appVersion = "0.1.0"
    public static let bundleIdentifier = "com.deskvanic.app"

    /// 应用支持目录（数据库、设置、日志、捕获数据等）。
    public static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Deskvanic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static var databaseURL: URL { supportDirectory.appendingPathComponent("Deskvanic.sqlite") }
    public static var settingsURL: URL { supportDirectory.appendingPathComponent("Settings.json") }
    public static var logsDirectory: URL { ensureSubdir("Logs") }
    public static var capturesDirectory: URL { ensureSubdir("Captures") }
    public static var vaultStorageDirectory: URL { ensureSubdir("VaultStorage") }
    public static var transfersDirectory: URL { ensureSubdir("Transfers") }
    public static var tempWorkingDirectory: URL { ensureSubdir("Tmp") }

    static func ensureSubdir(_ name: String) -> URL {
        let dir = supportDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
