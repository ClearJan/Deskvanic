import Foundation
import DeskvanicCore

/// 文本对比：LCS 逐行 diff。
public enum TextDiff {

    public enum ChangeType: Sendable, Hashable {
        case same
        case added
        case removed
    }

    public struct Change: Identifiable, Hashable, Sendable {
        public let id: Int
        public let type: ChangeType
        public let text: String

        init(id: Int, type: ChangeType, text: String) {
            self.id = id
            self.type = type
            self.text = text
        }
    }

    public struct Result: Sendable {
        public let changes: [Change]
        public let addedCount: Int
        public let removedCount: Int
        public let sameCount: Int
        /// 相似度（相同行比例），0...1。
        public let similarity: Double
    }

    /// 逐行 LCS diff（行数过大时护栏：超过 20 万行直接报错防内存爆炸）。
    public static func diff(left: String, right: String) throws -> Result {
        let leftLines = left.components(separatedBy: "\n")
        let rightLines = right.components(separatedBy: "\n")
        let limit = 200_000
        guard leftLines.count <= limit, rightLines.count <= limit else {
            throw DeskvanicError(
                .invalidInput,
                "文本过大（\(leftLines.count)/\(rightLines.count) 行），对比上限 \(limit) 行")
        }

        // LCS 动态规划（行数较小时用完整表；大表用滚动行减少内存——但需要回溯，此处限制总格数）
        let totalCells = leftLines.count * rightLines.count
        guard totalCells <= 40_000_000 else {
            throw DeskvanicError(
                .invalidInput, "两份文本行数乘积过大，无法完整对比（请缩小文本）")
        }

        let n = leftLines.count, m = rightLines.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if leftLines[i] == rightLines[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var changes: [Change] = []
        var i = 0, j = 0
        var added = 0, removed = 0, same = 0
        var id = 0
        while i < n && j < m {
            if leftLines[i] == rightLines[j] {
                changes.append(Change(id: id, type: .same, text: leftLines[i]))
                same += 1
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                changes.append(Change(id: id, type: .removed, text: leftLines[i]))
                removed += 1
                i += 1
            } else {
                changes.append(Change(id: id, type: .added, text: rightLines[j]))
                added += 1
                j += 1
            }
            id += 1
        }
        while i < n {
            changes.append(Change(id: id, type: .removed, text: leftLines[i]))
            removed += 1; i += 1; id += 1
        }
        while j < m {
            changes.append(Change(id: id, type: .added, text: rightLines[j]))
            added += 1; j += 1; id += 1
        }

        let totalLines = same + removed + added
        let similarity = totalLines == 0 ? 1 : Double(same) / Double(max(n, m, 1))
        return Result(changes: changes, addedCount: added, removedCount: removed,
                      sameCount: same, similarity: min(similarity, 1))
    }
}
