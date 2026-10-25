import AppKit
import Foundation
import DeskvanicCapture
import DeskvanicCore

/// GuideCraft 引擎：步骤捕获、标注、导出（Markdown/HTML/PDF）、敏感信息启发式检查。
/// 说明：不实现"自动识别点击位置/操作含义"（避免把猜测当作事实）；
/// 步骤由用户手动捕获并撰写说明，自动部分仅为截图与编号标注。
public struct GuideStep: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var description: String
    public let imagePath: String
    public let capturedAt: Date

    public init(id: String = UUID().uuidString, title: String, description: String,
                imagePath: String, capturedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.description = description
        self.imagePath = imagePath
        self.capturedAt = capturedAt
    }
}

public struct GuideDocument: Identifiable, Codable, Sendable {
    public let id: String
    public var title: String
    public var steps: [GuideStep]
    public let createdAt: Date

    public init(id: String = UUID().uuidString, title: String, steps: [GuideStep] = [], createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.steps = steps
        self.createdAt = createdAt
    }
}

public enum GuideEngine {

    // MARK: - 步骤捕获

    /// 捕获一个步骤（全屏截图，标注步骤编号；区域截图由 UI 调用区域选择后传入）。
    public static func captureStep(number: Int, title: String, region: CGRect? = nil,
                                   storageDirectory: URL) throws -> GuideStep {
        let image: CGImage?
        if let region {
            image = CaptureEngine.captureRegion(appKitRect: region)
        } else {
            image = CaptureEngine.captureFullScreen()
        }
        guard let image else {
            throw DeskvanicError(.permissionDenied, "截图失败（需要屏幕录制权限）",
                               recovery: "请在系统设置 → 隐私与安全性 → 屏幕录制 中允许 Deskvanic。")
        }
        // 步骤编号标注（左上角）
        let annotated = AnnotationEngine.drawText(
            image, text: "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮"[safe: number - 1].map(String.init) ?? "#\(number)",
            at: CGPoint(x: 24, y: 24),
            color: CGColor(red: 0.95, green: 0.35, blue: 0.1, alpha: 1),
            fontSize: 56) ?? image
        let url = try CaptureEngine.savePNG(annotated, to: storageDirectory)
        return GuideStep(title: title, description: "", imagePath: url.path)
    }

    // MARK: - 敏感信息启发式检查

    public struct PrivacyFinding: Sendable, Identifiable {
        public var id: String { keyword + "#" + stepID }
        public let stepID: String
        public let stepIndex: Int
        public let keyword: String
        public let snippet: String
    }

    /// 敏感信息启发式检查：对每个步骤截图跑 OCR，扫描关键词。
    /// 说明：这是"提醒用户人工复核"的辅助，不是隐私保证；结果允许误报/漏报。
    public static func privacyScan(
        document: GuideDocument, keywords: [String]? = nil
    ) async -> [PrivacyFinding] {
        let defaultKeywords = [
            "密码", "password", "passwd", "pwd", "token", "secret",
            "身份证", "银行卡", "信用卡", "api key", "apikey",
            "私钥", "authorization", "bearer",
        ]
        let list = keywords ?? defaultKeywords
        var findings: [PrivacyFinding] = []
        for (index, step) in document.steps.enumerated() {
            guard let image = NSImage(contentsOfFile: step.imagePath)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            guard let result = try? await OCREngine.recognizeText(in: image, minimumConfidence: 0.4) else { continue }
            let lower = result.fullText.lowercased()
            for keyword in list {
                if let range = lower.range(of: keyword.lowercased()) {
                    let start = lower.index(range.lowerBound, offsetBy: -min(12, lower.distance(from: lower.startIndex, to: range.lowerBound)), limitedBy: lower.startIndex) ?? lower.startIndex
                    let end = lower.index(range.upperBound, offsetBy: 24, limitedBy: lower.endIndex) ?? lower.endIndex
                    findings.append(PrivacyFinding(
                        stepID: step.id, stepIndex: index + 1, keyword: keyword,
                        snippet: String(lower[start..<end]).replacingOccurrences(of: "\n", with: " ")))
                }
            }
        }
        return findings
    }

    // MARK: - 导出

    /// Markdown 导出（图片复制到相对路径 assets/）。
    public static func exportMarkdown(document: GuideDocument, to directory: URL) throws -> URL {
        let assetsDir = directory.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        var markdown = "# \(document.title)\n\n"
        markdown += "> 生成于 \(document.createdAt.formatted(date: .long, time: .shortened)) · Deskvanic GuideCraft\n\n"
        for (index, step) in document.steps.enumerated() {
            let assetName = "step-\(index + 1).png"
            let imageURL = URL(fileURLWithPath: step.imagePath)
            if FileManager.default.fileExists(atPath: imageURL.path) {
                let dest = assetsDir.appendingPathComponent(assetName)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.copyItem(at: imageURL, to: dest)
                }
                markdown += "![步骤 \(index + 1)](assets/\(assetName))\n\n"
            }
            markdown += "### 步骤 \(index + 1)：\(step.title)\n\n"
            if !step.description.isEmpty {
                markdown += "\(step.description)\n\n"
            }
        }
        let output = FileSafety.uniqueDestination(in: directory, preferredName: "\(document.title).md")
        try markdown.data(using: .utf8)?.write(to: output, options: .atomic)
        try FileSafety.validateOutput(at: output)
        return output
    }

    /// 独立 HTML 导出（图片内嵌 base64，单文件可分发）。
    public static func exportHTML(document: GuideDocument, to directory: URL) throws -> URL {
        var html = """
        <!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(document.title)</title>
        <style>body{font-family:-apple-system,'PingFang SC',sans-serif;max-width:760px;margin:0 auto;padding:24px;line-height:1.7}
        img{max-width:100%;border:1px solid #ddd;border-radius:8px;margin:12px 0}
        h1{border-bottom:2px solid #eee;padding-bottom:8px}
        .step{margin:28px 0}.num{display:inline-block;background:#0a84ff;color:#fff;border-radius:50%;
        width:28px;height:28px;text-align:center;line-height:28px;margin-right:8px}
        footer{color:#999;font-size:13px;margin-top:40px}</style></head><body>
        <h1>\(document.title)</h1>

        """
        for (index, step) in document.steps.enumerated() {
            html += "<div class='step'><h2><span class='num'>\(index + 1)</span>\(escapeHTML(step.title))</h2>"
            if !step.description.isEmpty {
                html += "<p>\(escapeHTML(step.description))</p>"
            }
            if let data = try? Data(contentsOf: URL(fileURLWithPath: step.imagePath)) {
                html += "<img src='data:image/png;base64,\(data.base64EncodedString())' alt='步骤 \(index + 1)'>"
            }
            html += "</div>"
        }
        html += "<footer>由 Deskvanic GuideCraft 生成</footer></body></html>"
        let output = FileSafety.uniqueDestination(in: directory, preferredName: "\(document.title).html")
        try html.data(using: .utf8)?.write(to: output, options: .atomic)
        try FileSafety.validateOutput(at: output)
        return output
    }

    /// PDF 导出（标题页 + 每步骤图与说明，原生 PDFKit 绘制）。
    public static func exportPDF(document: GuideDocument, to directory: URL) throws -> URL {
        let pdf = PDFDocumentBuilder()
        pdf.addTitlePage(title: document.title, subtitle: "Deskvanic GuideCraft · \(document.createdAt.formatted(date: .long, time: .shortened))")
        for (index, step) in document.steps.enumerated() {
            pdf.addStepPage(number: index + 1, title: step.title, description: step.description,
                            imagePath: step.imagePath)
        }
        let output = try pdf.write(preferredName: "\(document.title).pdf", to: directory)
        try FileSafety.validateOutput(at: output)
        return output
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension String {
    subscript(safe index: Int) -> Character? {
        guard index >= 0, index < count else { return nil }
        return self[self.index(startIndex, offsetBy: index)]
    }
}

/// 简易 PDF 组装器（CoreGraphics 绘制）。
final class PDFDocumentBuilder {
    private struct Page {
        let size: CGSize
        let draw: (CGRect, CGContext) -> Void
    }

    private var pages: [Page] = []

    func addTitlePage(title: String, subtitle: String) {
        pages.append(Page(size: CGSize(width: 612, height: 792)) { _, context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            Self.drawText(title, at: CGPoint(x: 72, y: 620), font: .boldSystemFont(ofSize: 28), context: context)
            Self.drawText(subtitle, at: CGPoint(x: 72, y: 580), font: .systemFont(ofSize: 12), color: .gray, context: context)
        })
    }

    func addStepPage(number: Int, title: String, description: String, imagePath: String) {
        pages.append(Page(size: CGSize(width: 612, height: 792)) { _, context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
            Self.drawText("步骤 \(number)：\(title)", at: CGPoint(x: 60, y: 730),
                     font: .boldSystemFont(ofSize: 16), context: context)
            if !description.isEmpty {
                Self.drawTextWrapped(description, in: CGRect(x: 60, y: 660, width: 492, height: 50),
                                context: context)
            }
            if let image = NSImage(contentsOfFile: imagePath)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // 等比放入内容区
                let maxRect = CGRect(x: 60, y: 80, width: 492, height: 560)
                let scale = min(maxRect.width / CGFloat(image.width), maxRect.height / CGFloat(image.height))
                let drawRect = CGRect(
                    x: maxRect.minX + (maxRect.width - CGFloat(image.width) * scale) / 2,
                    y: maxRect.minY,
                    width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                context.draw(image, in: drawRect)
            }
        })
    }

    private static func drawText(_ text: String, at point: CGPoint, font: NSFont,
                          color: NSColor = .black, context: CGContext) {
        context.saveGState()
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawTextWrapped(_ text: String, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 0.25, alpha: 1))
        let attributed = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                       .foregroundColor: NSColor.darkGray])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.count), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    func write(preferredName: String, to directory: URL) throws -> URL {
        let output = FileSafety.uniqueDestination(in: directory, preferredName: preferredName)
        guard let consumer = CGDataConsumer(url: output as CFURL) else {
            throw DeskvanicError(.fileWriteFailed, "无法创建 PDF 输出")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DeskvanicError(.fileWriteFailed, "无法创建 PDF 上下文")
        }
        for page in pages {
            context.beginPage(mediaBox: &mediaBox)
            page.draw(mediaBox, context)
            context.endPage()
        }
        context.closePDF()
        return output
    }
}

import PDFKit
