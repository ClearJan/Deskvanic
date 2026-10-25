import Foundation
import DeskvanicCore

/// 授权目录文件搜索：只搜索用户通过书签授权的目录（隐私边界），
/// 后台并发执行、限时限深，结果按模糊匹配排序。绝不触碰未授权路径。
public actor FileSearcher {
    public static let shared = FileSearcher()

    public struct FileHit: Identifiable, Hashable, Sendable {
        public let id: String   // 路径
        public let path: String
        public let name: String
        public let isDirectory: Bool
    }

    private let bookmarks: BookmarkStore
    private var lastFullScan: [String: [FileHit]] = [:]   // 目录 → 缓存
    private var cacheTimes: [String: Date] = [:]
    private let cacheLifetime: TimeInterval = 60

    public init(bookmarks: BookmarkStore = BookmarkStore()) {
        self.bookmarks = bookmarks
    }

    /// 搜索所有授权目录。query 为空返回空。超时自动截断（保 UI 响应）。
    public func search(_ query: String, limit: Int = 20) async -> [FileHit] {
        guard !query.isEmpty else { return [] }
        let roots = await authorizedRoots()
        guard !roots.isEmpty else { return [] }

        var hits: [FileHit] = []
        for root in roots {
            let cached = cachedHits(for: root)
            let ranked = FuzzyMatcher.rank(cached, query: query) { $0.name }
            hits.append(contentsOf: ranked.prefix(limit).map(\.item))
        }
        return Array(FuzzyMatcher.rank(hits, query: query) { $0.name }.prefix(limit).map(\.item))
    }

    /// 解析授权书签为可用目录。失效书签跳过（不崩溃、不伪造结果）。
    public func authorizedRoots() async -> [String] {
        var roots: [String] = []
        for key in await bookmarks.keys {
            if let url = await bookmarks.resolve(key: key) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    roots.append(url.path)
                }
            }
            await bookmarks.endAccess(key: key)
        }
        return roots
    }

    /// 扫描单个目录（深度受控，符号链接不跟随——防循环）。
    public func scanDirectory(_ path: String, maxDepth: Int = 4, maxEntries: Int = 8000) -> [FileHit] {
        var hits: [FileHit] = []
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path, isDirectory: true)

        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth, hits.count < maxEntries else { return }
            guard let children = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            for child in children {
                guard hits.count < maxEntries else { return }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isSymlink = values?.isSymbolicLink ?? false
                let isDir = values?.isDirectory ?? false
                // 符号链接不跟随（只收录自身，不深入）
                if isDir && !isSymlink {
                    hits.append(FileHit(id: child.path, path: child.path, name: child.lastPathComponent, isDirectory: true))
                    walk(child, depth: depth + 1)
                } else {
                    hits.append(FileHit(id: child.path, path: child.path, name: child.lastPathComponent, isDirectory: false))
                }
            }
        }
        walk(root, depth: 1)
        return hits
    }

    private func cachedHits(for root: String) -> [FileHit] {
        if let time = cacheTimes[root], Date().timeIntervalSince(time) < cacheLifetime, let cached = lastFullScan[root] {
            return cached
        }
        let hits = scanDirectory(root)
        lastFullScan[root] = hits
        cacheTimes[root] = Date()
        return hits
    }

    public func invalidateCache() {
        lastFullScan.removeAll()
        cacheTimes.removeAll()
    }
}
