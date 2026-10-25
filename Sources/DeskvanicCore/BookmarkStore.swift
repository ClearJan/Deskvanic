import Foundation

/// 安全作用域书签存储：用户授权访问的文件夹以持久化书签形式保存，
/// 重启后无需再次授权。基于计数器保证 start/stop 配对。
public actor BookmarkStore {
    private let storageURL: URL
    private var bookmarks: [String: Data] = [:]
    private var accessCounts: [String: Int] = [:]

    public init(storageURL: URL = AppEnvironment.supportDirectory.appendingPathComponent("FolderBookmarks.json")) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([String: Data].self, from: data) {
            bookmarks = decoded
        }
    }

    public func saveBookmark(for folder: URL, key: String) throws {
        let data = try folder.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        bookmarks[key] = data
        persist()
    }

    public func removeBookmark(key: String) {
        bookmarks[key] = nil
        persist()
    }

    public var keys: [String] { Array(bookmarks.keys) }

    /// 解析书签并开始访问；返回可用的 URL，失败返回 nil。
    public func resolve(key: String) -> URL? {
        guard let data = bookmarks[key] else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale) else { return nil }
        if stale {
            guard let refreshed = try? url.bookmarkData(options: [.withSecurityScope]) else { return nil }
            bookmarks[key] = refreshed
            persist()
        }
        let started = url.startAccessingSecurityScopedResource()
        if started { accessCounts[key, default: 0] += 1 }
        return url
    }

    /// 与 resolve 配对结束访问。
    public func endAccess(key: String) {
        guard let data = bookmarks[key] else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: [.withSecurityScope],
            relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        if accessCounts[key] ?? 0 > 0 {
            accessCounts[key]? -= 1
            if accessCounts[key] == 0 {
                url.stopAccessingSecurityScopedResource()
                accessCounts[key] = nil
            }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? AtomicFileWriter.write(data: data, to: storageURL)
    }
}
