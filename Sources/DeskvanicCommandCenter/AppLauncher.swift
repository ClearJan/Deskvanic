import AppKit
import Foundation
import DeskvanicCore

/// 已安装应用发现与启动：扫描 /Applications 与 ~/Applications，
/// 结果缓存并提供模糊搜索。扫描在后台队列执行，绝不阻塞主线程。
public actor AppLauncher {
    public static let shared = AppLauncher()

    public struct AppEntry: Identifiable, Hashable, Sendable {
        public let id: String        // bundleIdentifier 或路径哈希
        public let name: String
        public let path: String
        public let bundleIdentifier: String?
    }

    private var cache: [AppEntry] = []
    private var cacheDate: Date?
    private let cacheLifetime: TimeInterval = 300

    public init() {}

    /// 扫描应用目录（含一级子目录，如 /Applications/Utilities）。跳过不可读目录。
    public func refreshIfNeeded(force: Bool = false) async -> [AppEntry] {
        if !force, let cacheDate, Date().timeIntervalSince(cacheDate) < cacheLifetime, !cache.isEmpty {
            return cache
        }
        let scanned = await Task.detached(priority: .utility) {
            Self.scanApplications()
        }.value
        cache = scanned
        cacheDate = Date()
        return scanned
    }

    /// 模糊搜索应用名。
    public func search(_ query: String, limit: Int = 10) async -> [AppEntry] {
        let apps = await refreshIfNeeded()
        guard !query.isEmpty else { return Array(apps.prefix(limit)) }
        return FuzzyMatcher.rank(apps, query: query) { $0.name }
            .prefix(limit)
            .map(\.item)
    }

    static func scanApplications() -> [AppEntry] {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        ]
        var results: [AppEntry] = []
        var seen = Set<String>()

        for root in roots {
            guard let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                guard child.pathExtension == "app" else { continue }
                let path = child.path
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                if let entry = makeEntry(url: child) { results.append(entry) }
                // 一级子目录中的 .app（Utilities 等）
                let subURL = child.deletingPathExtension()
                _ = subURL
            }
            // Utilities / Settings 等子目录
            for known in ["Utilities", "Settings"] {
                let sub = root.appendingPathComponent(known, isDirectory: true)
                guard let children2 = try? fm.contentsOfDirectory(
                    at: sub, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]) else { continue }
                for child in children2 where child.pathExtension == "app" {
                    let path = child.path
                    guard !seen.contains(path) else { continue }
                    seen.insert(path)
                    if let entry = makeEntry(url: child) { results.append(entry) }
                }
            }
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func makeEntry(url: URL) -> AppEntry? {
        let bundle = Bundle(path: url.path)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return AppEntry(
            id: bundle?.bundleIdentifier ?? ("path:" + url.path),
            name: name,
            path: url.path,
            bundleIdentifier: bundle?.bundleIdentifier)
    }
}
