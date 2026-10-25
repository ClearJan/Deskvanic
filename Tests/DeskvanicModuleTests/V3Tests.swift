import AppKit
import Foundation
import Testing
import DeskvanicCore
@testable import DeskvanicGuide
@testable import DeskvanicMedia
@testable import DeskvanicPaper
@testable import DeskvanicWeb

@Suite("PaperFieldExtractor")
struct PaperFieldExtractorTests {
    @Test func extractsAmountAndDate() {
        let text = "某某超市有限公司 发票代码 12345 日期：2026-03-15 合计：¥128.50 谢谢惠顾"
        let extracted = PaperFieldExtractor.extract(from: text)
        #expect(extracted.amount == 128.50)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: extracted.date ?? Date())
        #expect(components.year == 2026 && components.month == 3 && components.day == 15)
        #expect(extracted.merchant?.contains("超市") == true)
    }

    @Test func extractsChineseDateFormat() {
        let text = "2026年1月5日 购买 总金额 3,456.78 元"
        let extracted = PaperFieldExtractor.extract(from: text)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: extracted.date ?? Date())
        #expect(components.year == 2026 && components.month == 1 && components.day == 5)
        #expect(extracted.amount == 3456.78)
    }

    @Test func noGarbageExtraction() {
        let extracted = PaperFieldExtractor.extract(from: "随机文本 无金额 无日期")
        #expect(extracted.amount == nil)
        #expect(extracted.date == nil)
    }

    @Test func unreasonableAmountsRejected() {
        let text = "电话 13800138000 合计：¥99999999"
        let extracted = PaperFieldExtractor.extract(from: text)
        // 99999999 超过 10_000_000 上限被拒
        #expect(extracted.amount == nil)
    }
}

@Suite("WebContentFetcher")
struct WebContentFetcherTests {
    @Test func normalizeDeduplicates() {
        let a = WebContentFetcher.normalize("https://Example.com/path/?utm_source=x&id=1")
        let b = WebContentFetcher.normalize("https://example.com/path?id=1")
        #expect(a != nil && b != nil)
        #expect(a == b, "规范化后应视为同一 URL")
        let trailing = WebContentFetcher.normalize("https://example.com/path/?id=1")
        #expect(trailing == b)
    }

    @Test func normalizeRejectsNonHTTP() {
        #expect(WebContentFetcher.normalize("javascript:alert(1)") == nil)
        #expect(WebContentFetcher.normalize("ftp://x.com") == nil)
        #expect(WebContentFetcher.normalize("not a url") == nil)
    }

    @Test func extractTitleAndBody() {
        let html = """
        <html><head><title>测试页面标题</title>
        <meta name="description" content="页面描述文本"></head>
        <body><nav>导航链接</nav><script>var x=1;</script>
        <article><h1>正文标题</h1><p>这是正文内容，足够长的一段话，用来验证正文提取器能够正确剥离标签并保留文字内容。</p></article>
        <footer>页脚</footer></body></html>
        """
        #expect(WebContentFetcher.extractTitle(from: html) == "测试页面标题")
        #expect(WebContentFetcher.extractMetaDescription(from: html) == "页面描述文本")
        let body = WebContentFetcher.extractBodyText(from: html)
        #expect(body.contains("正文内容"))
        #expect(!body.contains("var x=1"))
        #expect(!body.contains("导航链接"))
        #expect(!body.contains("<p>"))
    }

    @Test func shortContentReportedAsFailure() {
        // 剥离后过短视为提取失败（返回空串）
        let tiny = "<html><body>短</body></html>"
        #expect(WebContentFetcher.extractBodyText(from: tiny) == "")
    }
}

@Suite("GuideEngine")
struct GuideEngineTests {
    private func makeDocument(in dir: URL) throws -> GuideDocument {
        let context = CGContext(
            data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let image = context.makeImage()!
        let imagePath = dir.appendingPathComponent("step.png")
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: imagePath)
        return GuideDocument(title: "测试教程", steps: [
            GuideStep(title: "打开应用", description: "从启动台打开 Deskvanic", imagePath: imagePath.path),
            GuideStep(title: "开始使用", description: "点击首页工具卡片", imagePath: imagePath.path),
        ])
    }

    @Test func exportMarkdownAndHTMLAndPDF() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-guide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let document = try makeDocument(in: dir)

        let md = try GuideEngine.exportMarkdown(document: document, to: dir)
        let mdContent = try String(contentsOf: md, encoding: .utf8)
        #expect(mdContent.contains("# 测试教程"))
        #expect(mdContent.contains("### 步骤 1：打开应用"))
        #expect(mdContent.contains("](assets/step-1.png)"))

        let html = try GuideEngine.exportHTML(document: document, to: dir)
        let htmlContent = try String(contentsOf: html, encoding: .utf8)
        #expect(htmlContent.contains("<title>测试教程</title>") || htmlContent.contains("测试教程"))
        #expect(htmlContent.contains("data:image/png;base64,"))

        let pdf = try GuideEngine.exportPDF(document: document, to: dir)
        #expect(FileManager.default.fileExists(atPath: pdf.path))
        // PDF 可打开且页数正确（标题页 + 2 步骤）
        guard let doc = PDFKitDocument(url: pdf) else {
            Issue.record("PDF 无法打开")
            return
        }
        #expect(doc.document.pageCount == 3)
    }

    @Test func privacyScanDetectsKeywords() async throws {
        // 用带文字的截图触发 OCR（Vision 需可读文本；生成含关键词的图）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let context = CGContext(
            data: nil, width: 900, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 200))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let font = NSFont.boldSystemFont(ofSize: 56)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Password: hunter2", attributes: [.font: font]))
        context.textPosition = CGPoint(x: 40, y: 80)
        CTLineDraw(line, context)
        let image = context.makeImage()!
        let imagePath = dir.appendingPathComponent("secret.png")
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: imagePath)

        let document = GuideDocument(title: "敏感", steps: [
            GuideStep(title: "登录", description: "", imagePath: imagePath.path),
        ])
        let findings = await GuideEngine.privacyScan(document: document, keywords: ["password"])
        #expect(!findings.isEmpty, "应发现 password 关键词")
    }
}

import CoreGraphics
import CoreText

@Suite("MediaEngine")
struct MediaEngineTests {
    /// 生成测试音频（正弦波 WAV，AVAudioFile 直写）。
    private func makeTestAudio(in dir: URL, seconds: Double = 2, name: String = "test-audio.wav") throws -> URL {
        let output = dir.appendingPathComponent(name)
        let sampleRate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: output, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let totalFrames = AVAudioFrameCount(seconds * sampleRate)
        let chunkSize = 44100
        var written = 0
        while written < Int(totalFrames) {
            let chunk = min(chunkSize, Int(totalFrames) - written)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { break }
            buffer.frameLength = AVAudioFrameCount(chunk)
            for i in 0..<chunk {
                buffer.floatChannelData![0][i] = sin(Float(written + i) * 0.05) * 0.3
            }
            try file.write(from: buffer)
            written += chunk
        }
        return output
    }

    @Test func inspectAudioInfo() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = try makeTestAudio(in: dir)
        let info = try await MediaEngine.inspect(url: audio)
        #expect(info.hasAudio)
        #expect(!info.hasVideo)
        #expect(info.durationSeconds > 1.5 && info.durationSeconds < 2.6)
    }

    @Test func trimAudioProducesShorterValidOutput() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = try makeTestAudio(in: dir)
        let output = try await MediaEngine.trim(source: audio, start: 0.2, end: 1.2, destinationDirectory: dir)
        let info = try await MediaEngine.inspect(url: output)
        #expect(info.durationSeconds > 0.7 && info.durationSeconds < 1.4)
    }

    @Test func waveformReturnsNormalizedBars() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-wav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = try makeTestAudio(in: dir, seconds: 1.5, name: "tone.wav")

        let peaks = try MediaEngine.waveform(url: output, barCount: 60)
        #expect(peaks.count == 60)
        #expect(peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(peaks.contains { $0 > 0.1 }, "正弦波应有可测振幅")
    }
}

import AVFoundation
