import Foundation
import os

/// 统一日志：os.Logger（系统日志 / 控制台）+ 滚动文件日志（应用支持目录）。
/// 文件日志按大小滚动，写入在专用串行队列上执行，绝不阻塞调用方。
public enum Log {
    public enum Category: String, Sendable {
        case app, core, capture, clipboard, files, vault, tools, command, network, voice, flow, audit, ui
    }

    private static let osLog = OSLog(subsystem: AppEnvironment.bundleIdentifier, category: "deskvanic")
    private static let queue = DispatchQueue(label: "com.deskvanic.app.filelog")
    private static let maxFileBytes = 2 * 1024 * 1024
    private static let maxRolledFiles = 3

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static var fileURL: URL {
        AppEnvironment.logsDirectory.appendingPathComponent("deskvanic.log")
    }

    public static func info(_ message: String, category: Category = .app) {
        log(message, level: "INFO", osType: .info, category: category)
    }

    public static func warning(_ message: String, category: Category = .app) {
        log(message, level: "WARN", osType: .default, category: category)
    }

    public static func error(_ message: String, category: Category = .app) {
        log(message, level: "ERROR", osType: .error, category: category)
    }

    public static func debug(_ message: String, category: Category = .app) {
        log(message, level: "DEBUG", osType: .debug, category: category)
    }

    private static func log(_ message: String, level: String, osType: OSLogType, category: Category) {
        let line = "\(formatter.string(from: Date())) [\(level)] [\(category.rawValue)] \(message)\n"
        os_log("%{private}@", log: osLog, type: osType, line)  // private：控制台聚合不含用户内容
        queue.async { appendToFile(line) }
    }

    private static func appendToFile(_ line: String) {
        let url = fileURL
        let fm = FileManager.default
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxFileBytes {
            rollFiles(at: url, fm: fm)
        }
        guard let data = line.data(using: .utf8) else { return }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: data)
        } else if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func rollFiles(at url: URL, fm: FileManager) {
        var newest = maxRolledFiles
        while newest >= 1 {
            let src = URL(fileURLWithPath: url.path + ".\(newest)")
            let dst = URL(fileURLWithPath: url.path + ".\(newest + 1)")
            try? fm.removeItem(at: dst)
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: dst)
            }
            newest -= 1
        }
        try? fm.moveItem(at: url, to: URL(fileURLWithPath: url.path + ".1"))
    }
}
