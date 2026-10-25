import AppKit
import Foundation
import DeskvanicCore

/// Markdown 渲染器：输出受控 NSAttributedString。
/// 安全模型：只解析结构化 Markdown 元素，不做任何 HTML/脚本解释；
/// 链接仅允许 http/https/mailto scheme，其余一律降级为纯文本。
public enum MarkdownRenderer {

    public enum Element: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case codeBlock(language: String?, code: String)
        case blockquote([String])
        case list(items: [ListItem], ordered: Bool)
        case divider
        case emptyLine
    }

    public struct ListItem: Equatable, Sendable {
        public let text: String
        public let level: Int
    }

    /// 解析为元素序列（纯函数，便于测试）。
    public static func parse(_ markdown: String) -> [Element] {
        let lines = markdown.components(separatedBy: "\n")
        var elements: [Element] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 空行
            if trimmed.isEmpty {
                elements.append(.emptyLine)
                index += 1
                continue
            }
            // 分隔线
            if trimmed == "---" || trimmed == "***" {
                elements.append(.divider)
                index += 1
                continue
            }
            // 代码块
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                elements.append(.codeBlock(
                    language: language.isEmpty ? nil : language,
                    code: code.joined(separator: "\n")))
                index += 1  // 跳过结束 ```
                continue
            }
            // 标题
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                if level <= 6, trimmed.count > level, trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " {
                    let text = String(trimmed.dropFirst(level + 1))
                    elements.append(.heading(level: level, text: text))
                    index += 1
                    continue
                }
            }
            // 引用（连续 > 行合并）
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let l = lines[index].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    quoted.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                elements.append(.blockquote(quoted))
                continue
            }
            // 列表（连续项合并；ordered/unordered 各自成块）
            if isListItem(trimmed) != nil {
                let ordered = trimmed.first?.isNumber == true
                var items: [ListItem] = []
                while index < lines.count {
                    let l = lines[index]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    guard let marker = isListItem(t) else {
                        // 缩进续行属于上一项
                        if l.hasPrefix(" ") || l.hasPrefix("\t"), !items.isEmpty {
                            items[items.count - 1] = ListItem(
                                text: items[items.count - 1].text + " " + t,
                                level: items[items.count - 1].level)
                            index += 1
                            continue
                        }
                        break
                    }
                    let level = l.count - l.trimmingCharacters(in: .whitespaces).count
                    let itemLevel = level / 2
                    let content = String(t.dropFirst(marker.count).trimmingCharacters(in: .whitespaces))
                    items.append(ListItem(text: content, level: itemLevel))
                    index += 1
                }
                elements.append(.list(items: items, ordered: ordered))
                continue
            }
            // 普通段落（连续非空非结构行合并）
            var paragraph: [String] = [trimmed]
            index += 1
            while index < lines.count {
                let t = lines[index].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("```") || t.hasPrefix(">")
                    || isListItem(t) != nil || t == "---" || t == "***" {
                    break
                }
                paragraph.append(t)
                index += 1
            }
            elements.append(.paragraph(paragraph.joined(separator: " ")))
        }
        return elements
    }

    /// 返回列表标记（"- " / "* " / "+ " / "1. "）。ordered 返回 "1. " 样式标记，unordered 返回 "- "。
    static func isListItem(_ trimmedLine: String) -> String? {
        if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("+ ") {
            return String(trimmedLine.prefix(2))
        }
        // 有序列表：数字 + . 或 )
        if let dotIndex = trimmedLine.firstIndex(where: { $0 == "." || $0 == ")" }) {
            let numberPart = String(trimmedLine[..<dotIndex])
            if !numberPart.isEmpty, numberPart.allSatisfy(\.isNumber), dotIndex != trimmedLine.startIndex {
                let after = trimmedLine.index(after: dotIndex)
                if after < trimmedLine.endIndex, trimmedLine[after] == " " {
                    return numberPart + String(trimmedLine[dotIndex])
                }
            }
        }
        return nil
    }

    // MARK: - 渲染

    /// 渲染为带样式的 NSAttributedString。
    /// 行内元素：**粗体**、*斜体*、`行内代码`、[文本](链接)。
    public static func render(_ markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 13)

        for element in parse(markdown) {
            switch element {
            case .emptyLine:
                output.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            case .divider:
                output.append(NSAttributedString(
                    string: String(repeating: "─", count: 40) + "\n",
                    attributes: [.font: baseFont, .foregroundColor: NSColor.separatorColor]))
            case .heading(let level, let text):
                let size: CGFloat = [26, 22, 18, 16, 14, 13][min(level, 6) - 1]
                output.append(NSAttributedString(
                    string: text + "\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: size, weight: .bold),
                        .foregroundColor: NSColor.textColor,
                    ]))
            case .paragraph(let text):
                output.append(inline(text, baseFont: baseFont))
                output.append(NSAttributedString(string: "\n"))
            case .codeBlock(_, let code):
                output.append(NSAttributedString(
                    string: code + "\n",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: NSColor.textColor,
                        .backgroundColor: NSColor.quaternarySystemFill,
                    ]))
            case .blockquote(let lines):
                for line in lines {
                    output.append(NSAttributedString(
                        string: "▌ " + line + "\n",
                        attributes: [
                            .font: baseFont,
                            .foregroundColor: NSColor.secondaryLabelColor,
                        ]))
                }
            case .list(let items, let ordered):
                for (position, item) in items.enumerated() {
                    let indent = String(repeating: "    ", count: item.level)
                    let marker = ordered ? "\(position + 1). " : "• "
                    output.append(NSAttributedString(
                        string: indent + marker,
                        attributes: [.font: baseFont, .foregroundColor: NSColor.secondaryLabelColor]))
                    output.append(inline(item.text, baseFont: baseFont))
                    output.append(NSAttributedString(string: "\n"))
                }
            }
        }
        return output
    }

    /// 行内解析：粗体/斜体/代码/链接。
    static func inline(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var remaining = Substring(text)

        while !remaining.isEmpty {
            // 依次尝试各类标记
            if let (matched, rest, attribute) = nextInlineToken(remaining, baseFont: baseFont) {
                result.append(matched)
                remaining = rest
                _ = attribute
            } else {
                // 普通字符（推进到下一个标记起点或结尾）
                var safeEnd = remaining.endIndex
                var advanced = false
                var scan = remaining.startIndex
                while scan < remaining.endIndex {
                    let character = remaining[scan]
                    if character == "*" || character == "`" || character == "[" {
                        safeEnd = scan
                        advanced = true
                        break
                    }
                    scan = remaining.index(after: scan)
                }
                let literal = remaining[..<safeEnd]
                result.append(NSAttributedString(string: String(literal), attributes: [.font: baseFont]))
                remaining = remaining[safeEnd...]
                if !advanced { break }
            }
        }
        return result
    }

    private typealias InlineToken = (NSAttributedString, Substring, String)

    private static func nextInlineToken(_ text: Substring, baseFont: NSFont) -> InlineToken? {
        let patterns: [(String, (String) -> InlineToken?)] = []
        _ = patterns  // 保留扩展点

        // 链接 [t](u)
        if text.hasPrefix("["),
           let bracketEnd = text.firstIndex(of: "]"),
           text.index(after: bracketEnd) < text.endIndex,
           text[text.index(after: bracketEnd)] == "(",
           let parenEnd = text[bracketEnd...].firstIndex(of: ")") {
            let linkText = String(text[text.index(after: text.startIndex)..<bracketEnd])
            let urlText = String(text[text.index(after: bracketEnd)..<parenEnd].dropFirst())
            if let url = sanitizedURL(urlText) {
                let attributed = NSAttributedString(
                    string: linkText,
                    attributes: [
                        .font: baseFont,
                        .link: url,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ])
                let rest = text[parenEnd...].dropFirst()
                return (attributed, rest, "link")
            }
            // 非法 scheme：整体降级纯文本
            let literal = String(text[...parenEnd])
            return (NSAttributedString(string: literal, attributes: [.font: baseFont]),
                    text[parenEnd...].dropFirst(), "link-dropped")
        }
        // 粗体 **t**
        if text.hasPrefix("**"),
           let end = text.dropFirst(2).range(of: "**") {
            let inner = String(text.dropFirst(2)[..<end.lowerBound])
            let attributed = NSAttributedString(
                string: inner,
                attributes: [.font: NSFont.boldSystemFont(ofSize: baseFont.pointSize)])
            let rest = text.dropFirst(2)[end.upperBound...]
            return (attributed, rest, "bold")
        }
        // 行内代码 `t`
        if text.hasPrefix("`"),
           let end = text.dropFirst(1).firstIndex(of: "`") {
            let inner = String(text.dropFirst(1)[..<end])
            let attributed = NSAttributedString(
                string: inner,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular),
                    .backgroundColor: NSColor.quaternarySystemFill,
                ])
            return (attributed, text.dropFirst(1)[text.index(after: end)...], "code")
        }
        // 斜体 *t*（不与 ** 冲突：已先查 **）
        if text.hasPrefix("*"),
           text.dropFirst(1).first == "*",
           let end = text.dropFirst(2).range(of: "**") {
            let inner = String(text.dropFirst(2)[..<end.lowerBound])
            let attributed = NSAttributedString(
                string: inner,
                attributes: [.font: NSFont.boldSystemFont(ofSize: baseFont.pointSize)])
            return (attributed, text.dropFirst(2)[end.upperBound...], "bold")
        }
        if text.hasPrefix("*"),
           let end = text.dropFirst(1).firstIndex(of: "*") {
            let inner = String(text.dropFirst(1)[..<end])
            if !inner.isEmpty {
                let attributed = NSAttributedString(
                    string: inner,
                    attributes: [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)])
                return (attributed, text.dropFirst(1)[text.index(after: end)...], "italic")
            }
        }
        return nil
    }

    /// 链接 scheme 白名单：http/https/mailto。其余返回 nil（降级为文本）。
    static func sanitizedURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }
}
