import Foundation
import DeskvanicCore

/// WebVault：网页资料库（URL 收藏、元数据抓取、正文提取、去重、阅读清单）。
/// 说明：正文提取为启发式 HTML 文本剥离（不做完整浏览器渲染）；
/// 动态页面/访问受限页面会如实标注提取失败，不伪造内容。
public struct WebItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var url: String
    public var title: String
    public var excerpt: String          // 元描述或正文摘要
    public var contentText: String      // 提取的正文（可空）
    public var tags: [String]
    public var isRead: Bool
    public var fetchFailed: Bool
    public let createdAt: Date

    public init(id: String = UUID().uuidString, url: String, title: String, excerpt: String = "",
                contentText: String = "", tags: [String] = [], isRead: Bool = false,
                fetchFailed: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.excerpt = excerpt
        self.contentText = contentText
        self.tags = tags
        self.isRead = isRead
        self.fetchFailed = fetchFailed
        self.createdAt = createdAt
    }
}

public enum WebContentFetcher {

    /// 规范化 URL（去 utm_*、尾斜杠、fragment、大小写 host）用于重复识别。
    public static func normalize(_ urlString: String) -> String? {
        guard var components = URLComponents(string: urlString.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil
        components.queryItems = components.queryItems?.filter { item in
            !item.name.lowercased().hasPrefix("utm_")
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        var path = components.path
        if path.hasSuffix("/") && path != "/" {
            path = String(path.dropLast())
        }
        components.path = path
        return components.string
    }

    /// 抓取网页标题、描述与正文（5 秒超时；仅 http/https；跟随重定向）。
    public static func fetch(urlString: String) async throws -> (title: String, excerpt: String, content: String) {
        guard let normalized = normalize(urlString), let url = URL(string: normalized) else {
            throw DeskvanicError(.invalidInput, "仅支持 http/https 链接")
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) Deskvanic/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        // 响应体上限 20MB（审计 #21）
        guard data.count <= 20 * 1024 * 1024 else {
            throw DeskvanicError(.invalidInput, "网页内容超过 20MB 上限，已放弃抓取")
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw DeskvanicError(.networkFailure, "网页请求失败（状态码 \((response as? HTTPURLResponse)?.statusCode ?? -1)）",
                               recovery: "页面可能访问受限或已下线；可保存标题后手动补充说明。")
        }
        // 编码推断
        let encoding: String.Encoding = httpResponse.textEncodingName?.lowercased().contains("gb") == true
            ? String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            : .utf8
        let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) ?? ""
        let title = extractTitle(from: html) ?? url.host ?? urlString
        let excerpt = extractMetaDescription(from: html) ?? ""
        let content = extractBodyText(from: html)
        return (title, excerpt, content)
    }

    static func extractTitle(from html: String) -> String? {
        guard let start = html.range(of: "<title", options: .caseInsensitive),
              let openEnd = html.range(of: ">", range: start.upperBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: openEnd.upperBound..<html.endIndex) else {
            return nil
        }
        let raw = String(html[openEnd.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : decodeEntities(raw)
    }

    static func extractMetaDescription(from html: String) -> String? {
        for pattern in ["<meta[^>]*name=[\"']description[\"'][^>]*>",
                        "<meta[^>]*property=[\"']og:description[\"'][^>]*>"] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, range: range),
               let matchRange = Range(match.range, in: html) {
                let tag = String(html[matchRange])
                if let contentRange = tag.range(of: "content=\"", options: .caseInsensitive) {
                    let after = tag[contentRange.upperBound...]
                    if let quoteEnd = after.firstIndex(of: "\"") {
                        let value = String(after[..<quoteEnd])
                        if !value.isEmpty { return decodeEntities(value) }
                    }
                }
            }
        }
        return nil
    }

    /// 启发式正文提取：优先 <article>/<main>，剥离脚本样式标签与全部标记。
    static func extractBodyText(from html: String) -> String {
        var working = html
        // 优先正文容器（<article>/<main> 到对应闭合标签）
        for container in ["article", "main"] {
            guard let openStart = working.range(of: "<\(container)", options: [.caseInsensitive, .regularExpression]),
                  let openTagEnd = working.range(of: ">", range: openStart.upperBound..<working.endIndex) else { continue }
            let closePattern = "</\(container)"
            if let close = working.range(of: closePattern, options: .caseInsensitive, range: openTagEnd.upperBound..<working.endIndex) {
                working = String(working[openTagEnd.upperBound..<close.lowerBound])
                break
            }
        }
        // 剥离脚本与样式
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header"] {
            working = working.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // 剥离所有标签
        working = working.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        working = working.replacingOccurrences(of: "&nbsp;", with: " ")
        working = working.replacingOccurrences(of: "&amp;", with: "&")
        working = working.replacingOccurrences(of: "&lt;", with: "<")
        working = working.replacingOccurrences(of: "&gt;", with: ">")
        working = working.replacingOccurrences(of: "&quot;", with: "\"")
        // 压缩空白
        working = working.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let trimmed = working.trimmingCharacters(in: .whitespacesAndNewlines)
        // 正文太短视为提取失败（动态页面）
        return trimmed.count >= 30 ? String(trimmed.prefix(20_000)) : ""
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

/// WebVault 存储（数据库 v12）。
public actor WebVaultStore {
    private let db: Database

    public init(database: Database) {
        self.db = database
    }

    /// 新增（规范化去重）。返回 (条目, 是否新增)；重复时返回已有条目。
    @discardableResult
    public func add(url: String, tags: [String]) async throws -> (WebItem, Bool) {
        guard let normalized = WebContentFetcher.normalize(url) else {
            throw DeskvanicCore.DeskvanicError(.invalidInput, "仅支持 http/https 链接")
        }
        // 重复识别
        let existing = try await all()
        if let duplicate = existing.first(where: { WebContentFetcher.normalize($0.url) == normalized }) {
            return (duplicate, false)
        }
        // 抓取元数据
        var item = WebItem(id: UUID().uuidString, url: normalized, title: normalized, tags: tags)
        do {
            let fetched = try await WebContentFetcher.fetch(urlString: normalized)
            item.title = fetched.title
            item.excerpt = fetched.excerpt
            item.contentText = fetched.content
        } catch {
            item.fetchFailed = true
            item.title = URL(string: normalized)?.host ?? normalized
            item.excerpt = "抓取失败：\(String(describing: error))"
        }
        try await save(item)
        return (item, true)
    }

    public func save(_ item: WebItem) async throws {
        let data = try JSONEncoder().encode(item)
        _ = try await db.runUpdate(
            "INSERT OR REPLACE INTO web_items(id, url, data, created_at) VALUES(?,?,?,?)",
            [.text(item.id), .text(item.url), .blob(data), .text(DateCodec.encode(item.createdAt))])
        let searchText = [item.title, item.excerpt, item.contentText, item.tags.joined(separator: " ")]
            .joined(separator: "\n")
        try await SearchIndex(database: db).upsert(type: "web", ref: item.id, text: searchText)
    }

    public func delete(id: String) async throws {
        _ = try await db.runUpdate("DELETE FROM web_items WHERE id = ?", [.text(id)])
        try await SearchIndex(database: db).remove(type: "web", ref: id)
    }

    public func all() async throws -> [WebItem] {
        let rows = try await db.run("SELECT data FROM web_items ORDER BY created_at DESC")
        return rows.compactMap { row in
            guard let data = row["data"]?.blobValue else { return nil }
            return try? JSONDecoder().decode(WebItem.self, from: data)
        }
    }

    /// 与 Recall Vault 统一检索：内容已入 FTS（type=web），此处只回本地列表。
    public func search(_ query: String) async throws -> [WebItem] {
        guard !query.isEmpty else { return try await all() }
        let index = SearchIndex(database: db)
        let hits = (try? await index.search(query, limit: 50)) ?? []
        let ids = Set(hits.filter { $0.type == "web" }.map(\.ref))
        let all = try await all()
        return all.filter { ids.contains($0.id) }
    }
}

/// WebVault 数据库迁移（版本 12）。
public enum WebVaultSchema {
    public static let migration = DBMigration(version: 12, name: "web-vault", statements: [
        """
        CREATE TABLE web_items(
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            data BLOB NOT NULL,
            created_at TEXT NOT NULL
        )
        """,
        "CREATE INDEX idx_web_created ON web_items(created_at DESC)",
    ])
}
