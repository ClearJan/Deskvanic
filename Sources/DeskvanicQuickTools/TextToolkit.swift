import Foundation
import DeskvanicCore

/// 文本工具集：清理、查找替换、大小写、行操作与统计（全部纯函数）。
public enum TextToolkit {

    // MARK: - 清理

    public struct CleanOptions: OptionSet, Codable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// 全角字符→半角（拉丁字母、数字、常用符号与空格）
        public static let fullWidthToHalf = CleanOptions(rawValue: 1 << 0)
        /// 去除行尾空白
        public static let trimTrailingWhitespace = CleanOptions(rawValue: 1 << 1)
        /// 连续 3 个以上空行压缩为 1 个空行
        public static let collapseBlankLines = CleanOptions(rawValue: 1 << 2)
        /// 修复中文段落内被硬换行打断的句子（删除中文字符之间的单个换行）
        public static let joinCJKLines = CleanOptions(rawValue: 1 << 3)
    }

    public static func clean(_ text: String, options: CleanOptions) -> String {
        var result = text
        if options.contains(.fullWidthToHalf) {
            result = result.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? result
        }
        var lines = result.components(separatedBy: "\n")
        if options.contains(.trimTrailingWhitespace) {
            lines = lines.map { line in
                var l = line
                while let last = l.last, last == " " || last == "\t" || last == "\r" {
                    l.removeLast()
                }
                return l
            }
        }
        if options.contains(.joinCJKLines) {
            lines = joinCJKBrokenLines(lines)
        }
        result = lines.joined(separator: "\n")
        if options.contains(.collapseBlankLines) {
            result = collapseBlankLines(in: result)
        }
        return result
    }

    /// 中文行合并：按空行分块，块内仅当行尾与下一行行首都是 CJK 字符时合并；
    /// 列表/标题/引用等结构行与其后内容不合并（保留文档结构）。
    static func joinCJKBrokenLines(_ lines: [String]) -> [String] {
        guard lines.count > 1 else { return lines }
        var output: [String] = []
        var block: [String] = []

        func flushBlock() {
            guard !block.isEmpty else { return }
            var buffer = ""
            for line in block {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if buffer.isEmpty {
                    buffer = line
                } else if isStructuralLine(buffer) || isStructuralLine(trimmed) {
                    output.append(buffer)
                    buffer = line
                } else if let lastChar = buffer.last, isCJK(lastChar),
                          let firstChar = trimmed.first, isCJK(firstChar) {
                    buffer += trimmed
                } else {
                    output.append(buffer)
                    buffer = line
                }
            }
            if !buffer.isEmpty { output.append(buffer) }
            block.removeAll()
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushBlock()
                output.append(line)
            } else {
                block.append(line)
            }
        }
        flushBlock()
        return output
    }

    /// 结构行：列表项、标题、引用——不与相邻行合并。
    static func isStructuralLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
            || trimmed.hasPrefix("#") || trimmed.hasPrefix(">")
            || isListItemNumbered(trimmed)
    }

    static func isListItemNumbered(_ trimmed: String) -> Bool {
        guard let dotIndex = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }),
              dotIndex != trimmed.startIndex else { return false }
        let numberPart = String(trimmed[..<dotIndex])
        return !numberPart.isEmpty && numberPart.allSatisfy(\.isNumber)
    }

    static func collapseBlankLines(in text: String) -> String {
        var output: [String] = []
        var blankRun = 0
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun <= 1 { output.append("") }  // 最多保留一个空行
            } else {
                blankRun = 0
                output.append(line)
            }
        }
        // 去掉首尾多余空行
        while let first = output.first, first.isEmpty { output.removeFirst() }
        while let last = output.last, last.isEmpty { output.removeLast() }
        return output.joined(separator: "\n")
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    // MARK: - 查找替换

    public struct ReplaceOptions: Sendable {
        public var caseSensitive: Bool
        public var wholeWords: Bool
        public var isRegex: Bool

        public init(caseSensitive: Bool = false, wholeWords: Bool = false, isRegex: Bool = false) {
            self.caseSensitive = caseSensitive
            self.wholeWords = wholeWords
            self.isRegex = isRegex
        }
    }

    /// 查找替换。返回 (新文本, 替换次数)。正则非法时抛错而不是崩溃。
    public static func findReplace(
        _ text: String, find: String, replacement: String, options: ReplaceOptions
    ) throws -> (String, Int) {
        guard !find.isEmpty else { return (text, 0) }
        let anchorStart = options.wholeWords ? "\\b" : ""
        let anchorEnd = options.wholeWords ? "\\b" : ""
        let escaped = options.isRegex ? find : NSRegularExpression.escapedPattern(for: find)
        let pattern = anchorStart + escaped + anchorEnd
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(
                pattern: pattern,
                options: options.caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw DeskvanicError(
                .invalidInput, "正则表达式无效：\(error.localizedDescription)",
                recovery: "请检查正则语法，或关闭正则模式。")
        }
        var count = 0
        let range = NSRange(text.startIndex..., in: text)
        let result = regex.stringByReplacingMatches(
            in: text, options: [], range: range,
            withTemplate: options.isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement))
        regex.enumerateMatches(in: text, options: [], range: range) { _, _, _ in count += 1 }
        return (result, count)
    }

    // MARK: - 大小写转换

    public enum CaseStyle: String, CaseIterable, Sendable {
        case upper, lower, capitalized, sentence, camel, snake, kebab

        public var displayName: String {
            switch self {
            case .upper: return "全部大写"
            case .lower: return "全部小写"
            case .capitalized: return "词首大写"
            case .sentence: return "句子大写"
            case .camel: return "camelCase"
            case .snake: return "snake_case"
            case .kebab: return "kebab-case"
            }
        }
    }

    public static func convertCase(_ text: String, style: CaseStyle) -> String {
        switch style {
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .capitalized: return text.capitalized
        case .sentence:
            return text.components(separatedBy: "\n").map { line in
                guard let first = line.first else { return line }
                return String(first).uppercased() + line.dropFirst()
            }.joined(separator: "\n")
        case .camel, .snake, .kebab:
            // 分词：按空白、标点与驼峰边界切分
            let words = tokenizeWords(text)
            switch style {
            case .camel:
                return words.enumerated().map { index, word in
                    index == 0 ? word.lowercased() : word.capitalized
                }.joined()
            case .snake:
                return words.map { $0.lowercased() }.joined(separator: "_")
            case .kebab:
                return words.map { $0.lowercased() }.joined(separator: "-")
            default: return text
            }
        }
    }

    static func tokenizeWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLower = false
        for character in text {
            if character.isLetter || character.isNumber {
                if previousWasLower && character.isUppercase && !current.isEmpty {
                    words.append(current)
                    current = String(character)
                } else {
                    current.append(character)
                }
                previousWasLower = character.isLowercase
            } else {
                if !current.isEmpty { words.append(current); current = "" }
                previousWasLower = false
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: - 行操作

    public enum LineOperation: String, CaseIterable, Sendable {
        case sortAscending = "升序排序"
        case sortDescending = "降序排序"
        case sortNatural = "自然排序（a2 < a10）"
        case deduplicate = "去重（保留首次出现）"
        case reverse = "反转行序"
        case removeEmpty = "删除空行"
        case trimLines = "去除每行首尾空白"

        public func apply(_ lines: [String]) -> [String] {
            switch self {
            case .sortAscending: return lines.sorted()
            case .sortDescending: return lines.sorted(by: >)
            case .sortNatural: return lines.enumerated().sorted { lhs, rhs in
                let a = lhs.element, b = rhs.element
                if a == b { return lhs.offset < rhs.offset }
                return compareNatural(a, b) == .orderedAscending
            }.map(\.element)
            case .deduplicate:
                var seen = Set<String>()
                return lines.filter { seen.insert($0).inserted }
            case .reverse: return lines.reversed()
            case .removeEmpty: return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            case .trimLines: return lines.map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
    }

    /// 自然比较：数字段按数值比较（a2 < a10）。
    public static func compareNatural(_ a: String, _ b: String) -> ComparisonResult {
        var ia = a.startIndex, ib = b.startIndex
        while ia < a.endIndex && ib < b.endIndex {
            let ca = a[ia], cb = b[ib]
            if ca.isNumber && cb.isNumber {
                var ja = ia, jb = ib
                while ja < a.endIndex, a[ja].isNumber { ja = a.index(after: ja) }
                while jb < b.endIndex, b[jb].isNumber { jb = b.index(after: jb) }
                let numA = Int(a[ia..<ja]) ?? 0
                let numB = Int(b[ib..<jb]) ?? 0
                if numA != numB { return numA < numB ? .orderedAscending : .orderedDescending }
                ia = ja; ib = jb
            } else if ca != cb {
                return ca < cb ? .orderedAscending : .orderedDescending
            } else {
                ia = a.index(after: ia); ib = b.index(after: ib)
            }
        }
        let aDone = ia >= a.endIndex, bDone = ib >= b.endIndex
        if aDone && bDone { return .orderedSame }
        return aDone ? .orderedAscending : .orderedDescending
    }

    // MARK: - 统计

    public struct TextStatistics: Codable, Hashable, Sendable {
        public let characters: Int        // Unicode 字符数
        public let words: Int             // CJK 单字 + 拉丁单词
        public let lines: Int
        public let bytes: Int
        public let cjkCharacters: Int
    }

    /// 混合统计：拉丁字母连续段记 1 词，每个 CJK 字符记 1 词。
    public static func statistics(_ text: String) -> TextStatistics {
        var words = 0
        var inLatinWord = false
        var cjkCount = 0
        for character in text {
            if isCJK(character) {
                words += 1
                cjkCount += 1
                inLatinWord = false
            } else if character.isLetter {
                if !inLatinWord { words += 1; inLatinWord = true }
            } else {
                inLatinWord = false
            }
        }
        return TextStatistics(
            characters: text.count,
            words: words,
            lines: text.isEmpty ? 0 : text.components(separatedBy: "\n").count,
            bytes: text.utf8.count,
            cjkCharacters: cjkCount)
    }
}
