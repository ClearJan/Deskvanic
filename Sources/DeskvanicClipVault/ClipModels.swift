import Foundation
import DeskvanicCore

/// 剪贴板条目类型。
public enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text
    case url
    case image
    case files

    public var displayName: String {
        switch self {
        case .text: return "文本"
        case .url: return "链接"
        case .image: return "图片"
        case .files: return "文件"
        }
    }
}

/// 一条剪贴板历史记录。
public struct ClipEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let kind: ClipKind
    /// 文本或 URL 内容；文件引用时为换行分隔的路径列表。
    public let contentText: String?
    /// 图片等二进制产物的落盘路径（Captures/Clips 下）。
    public let filePath: String?
    /// 列表预览文本（截断）。
    public let preview: String
    public let byteSize: Int
    /// 来源应用 bundleID（归属为启发式：变化时刻的前台应用），可为空。
    public let sourceApp: String?
    public var pinned: Bool
    public var favorite: Bool
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: ClipKind,
        contentText: String? = nil,
        filePath: String? = nil,
        preview: String,
        byteSize: Int = 0,
        sourceApp: String? = nil,
        pinned: Bool = false,
        favorite: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.contentText = contentText
        self.filePath = filePath
        self.preview = preview
        self.byteSize = byteSize
        self.sourceApp = sourceApp
        self.pinned = pinned
        self.favorite = favorite
        self.createdAt = createdAt
    }
}

/// 快捷文本模板。
public struct ClipTemplate: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var content: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, name: String, content: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.content = content
        self.createdAt = createdAt
    }
}

/// 剪贴板内容分类（纯函数，便于测试）：给定候选类型与文本负载，判断条目类型。
public enum ClipClassifier {
    public struct Snapshot: Sendable, Equatable {
        /// NSPasteboard types（有序）。
        public let types: [String]
        /// public.utf8-plain-text 负载（可能为空）。
        public let utf8Text: String?
        /// public.file-url（一个或多个）解码后的路径。
        public let fileURLs: [String]
        /// public.url 负载。
        public let urlText: String?
        /// 图片数据字节数（public.png / public.tiff 存在时）。
        public let imageSizeBytes: Int

        public init(
            types: [String], utf8Text: String?, fileURLs: [String],
            urlText: String?, imageSizeBytes: Int
        ) {
            self.types = types
            self.utf8Text = utf8Text
            self.fileURLs = fileURLs
            self.urlText = urlText
            self.imageSizeBytes = imageSizeBytes
        }
    }

    public enum Classification: Sendable, Equatable {
        case image(sizeBytes: Int)
        case files(paths: [String])
        case url(String)
        case text(String)
        case ignored
    }

    /// 分类优先级：图片 > 文件引用 > URL > 文本 > 忽略（空内容）。
    public static func classify(_ snapshot: Snapshot) -> Classification {
        if snapshot.imageSizeBytes > 0
            && (snapshot.types.contains("public.png") || snapshot.types.contains("public.tiff")) {
            return .image(sizeBytes: snapshot.imageSizeBytes)
        }
        if !snapshot.fileURLs.isEmpty {
            return .files(paths: snapshot.fileURLs)
        }
        if let urlText = snapshot.urlText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !urlText.isEmpty,
           let url = URL(string: urlText),
           url.scheme == nil || ["http", "https", "ftp", "file"].contains(url.scheme?.lowercased() ?? "") {
            return .url(url.absoluteString)
        }
        if let text = snapshot.utf8Text, !text.isEmpty {
            // 文本本身是 URL 的情况
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= 4096,
               let url = URL(string: trimmed),
               let scheme = url.scheme?.lowercased(),
               ["http", "https"].contains(scheme) {
                return .url(trimmed)
            }
            return .text(text)
        }
        return .ignored
    }
}

/// 自动清理与容量策略（纯函数，便于测试）。
public enum ClipRetentionPolicy {
    /// 返回应删除的条目 ID：超出保留天数且未被固定/收藏的、以及超出容量上限的最旧未固定条目。
    public static func staleIDs(
        entries: [ClipEntry],
        now: Date,
        retentionDays: Int,
        maxItems: Int
    ) -> Set<String> {
        guard retentionDays > 0 || maxItems > 0 else { return [] }
        var doomed = Set<String>()

        if retentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
            for entry in entries where !entry.pinned && !entry.favorite && entry.createdAt < cutoff {
                doomed.insert(entry.id)
            }
        }

        if maxItems > 0 {
            let survivors = entries
                .filter { !doomed.contains($0.id) }
                .sorted { $0.createdAt > $1.createdAt }
            var kept = 0
            for entry in survivors {
                if entry.pinned || entry.favorite {
                    kept += 1
                    continue
                }
                kept += 1
                if kept > maxItems {
                    doomed.insert(entry.id)
                }
            }
        }
        return doomed
    }
}
