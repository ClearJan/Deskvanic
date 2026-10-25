import AppKit
import CoreGraphics
import Foundation
import Testing
import DeskvanicCore
@testable import DeskvanicCapture

/// 测试辅助：程序化生成图像。
enum CaptureTestImages {
    /// 纯色图。
    static func solid(width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat) = (0.2, 0.4, 0.8)) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// 白底黑字文本图（用于 OCR 测试）。
    static func textImage(_ text: String, width: Int = 800, height: Int = 200) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        let font = NSFont.systemFont(ofSize: 56, weight: .bold)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: height / 2 - 20)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    /// 一次性解码为 RGBA 字节缓冲（左下原点，每像素 4 字节）。
    static func decode(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    /// 读取像素颜色（左下原点）。
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let buffer = decode(image)
        let idx = (y * image.width + x) * 4
        guard idx + 3 < buffer.count else { return (0, 0, 0, 0) }
        return (CGFloat(buffer[idx]) / 255, CGFloat(buffer[idx + 1]) / 255,
                CGFloat(buffer[idx + 2]) / 255, CGFloat(buffer[idx + 3]) / 255)
    }

    /// 区域平均颜色差（0...1），用于模糊效果断言。
    static func regionDifference(_ a: CGImage, _ b: CGImage, rect: CGRect) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        let bufA = decode(a)
        let bufB = decode(b)
        let sampleStep = max(1, Int(rect.width / 12))
        var totalDiff = 0.0
        var samples = 0
        var x = Int(rect.minX)
        while x < Int(rect.maxX) && x < a.width {
            var y = Int(rect.minY)
            while y < Int(rect.maxY) && y < a.height {
                let ia = (y * a.width + x) * 4
                let ib = (y * b.width + x) * 4
                for c in 0..<3 {
                    totalDiff += abs(Double(bufA[ia + c]) - Double(bufB[ib + c])) / 255
                }
                samples += 1
                y += sampleStep
            }
            x += sampleStep
        }
        return samples > 0 ? totalDiff / Double(samples * 3) : 0
    }
}

@Suite("AnnotationEngine")
struct AnnotationEngineTests {
    @Test func cropReducesSizeAndKeepsContent() {
        let image = CaptureTestImages.solid(width: 200, height: 100)
        let cropped = AnnotationEngine.crop(image, rect: CGRect(x: 10, y: 10, width: 100, height: 50))
        #expect(cropped?.width == 100)
        #expect(cropped?.height == 50)
    }

    @Test func cropClampsOutOfBounds() {
        let image = CaptureTestImages.solid(width: 100, height: 100)
        let cropped = AnnotationEngine.crop(image, rect: CGRect(x: 50, y: 50, width: 500, height: 500))
        #expect(cropped?.width == 50)
        #expect(cropped?.height == 50)
        // 完全出界返回 nil
        #expect(AnnotationEngine.crop(image, rect: CGRect(x: 200, y: 200, width: 10, height: 10)) == nil)
    }

    @Test func blurActuallyDestroysPixels() {
        // 用文本图：模糊后区域内像素应显著变化；区域外不变
        let image = CaptureTestImages.textImage("SECRET TEXT")
        let region = CGRect(x: 100, y: 60, width: 300, height: 60)
        let blurred = AnnotationEngine.blurRegion(image, rect: region, radius: 16)
        #expect(blurred != nil)
        let insideDiff = CaptureTestImages.regionDifference(image, blurred!, rect: region)
        #expect(insideDiff > 0.03, "模糊区域内像素应被破坏，实际差异 \(insideDiff)")

        // 区域外（左上角纯白背景）应保持不变
        let outsideDiff = CaptureTestImages.regionDifference(image, blurred!, rect: CGRect(x: 0, y: 150, width: 60, height: 40))
        #expect(outsideDiff < 0.01, "模糊不应影响区域外像素，实际差异 \(outsideDiff)")
    }

    @Test func blurRejectsInvalidRadius() {
        let image = CaptureTestImages.solid(width: 50, height: 50)
        #expect(AnnotationEngine.blurRegion(image, rect: CGRect(x: 0, y: 0, width: 20, height: 20), radius: 0) == nil)
        #expect(AnnotationEngine.blurRegion(image, rect: CGRect(x: 0, y: 0, width: 20, height: 20), radius: 100) == nil)
        #expect(AnnotationEngine.blurRegion(image, rect: .zero, radius: 8) == nil)
    }

    @Test func drawRectAddsColoredStroke() {
        let image = CaptureTestImages.solid(width: 100, height: 100, color: (1, 1, 1))
        let marked = AnnotationEngine.drawRect(
            image, rect: CGRect(x: 10, y: 10, width: 60, height: 60),
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(marked != nil)
        // 解码缓冲为自上而下内存序：CG 底边 y=10 ↔ 缓冲 y=90；CG 顶边 y=70 ↔ 缓冲 y=30
        let bottomEdge = CaptureTestImages.pixel(marked!, x: 40, y: 90)
        #expect(bottomEdge.0 > 0.8 && bottomEdge.1 < 0.3 && bottomEdge.2 < 0.3,
                "底边应为红色，实际 \(bottomEdge)")
        let topEdge = CaptureTestImages.pixel(marked!, x: 40, y: 30)
        #expect(topEdge.0 > 0.8 && topEdge.1 < 0.3 && topEdge.2 < 0.3,
                "顶边应为红色，实际 \(topEdge)")
        // 中心像素保持白色
        let center = CaptureTestImages.pixel(marked!, x: 40, y: 50)
        #expect(center.0 > 0.9 && center.1 > 0.9 && center.2 > 0.9)
    }

    @Test func drawArrowAddsColoredHead() {
        let image = CaptureTestImages.solid(width: 200, height: 200, color: (1, 1, 1))
        let marked = AnnotationEngine.drawArrow(
            image, start: CGPoint(x: 20, y: 100), end: CGPoint(x: 160, y: 100),
            color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        #expect(marked != nil)
        // 箭头终点附近应为蓝色
        let tip = CaptureTestImages.pixel(marked!, x: 158, y: 100)
        #expect(tip.2 > 0.7)
    }

    @Test func drawTextRendersVisibleInk() {
        let image = CaptureTestImages.solid(width: 300, height: 100, color: (1, 1, 1))
        let marked = AnnotationEngine.drawText(
            image, text: "标注", at: CGPoint(x: 50, y: 40),
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        #expect(marked != nil)
        // 文字区域出现黑色像素（抽样）
        var foundInk = false
        for x in stride(from: 50, to: 200, by: 4) {
            for y in stride(from: 20, to: 80, by: 2) {
                let p = CaptureTestImages.pixel(marked!, x: x, y: y)
                if p.0 < 0.4 && p.1 < 0.4 && p.2 < 0.4 { foundInk = true; break }
            }
        }
        #expect(foundInk, "文字应在指定区域产生可见墨迹")
    }

    @Test func scaleDownRespectsMaxPixel() {
        let image = CaptureTestImages.solid(width: 4000, height: 3000)
        let scaled = AnnotationEngine.scaleDown(image, maxPixel: 1000)
        #expect(scaled.width == 1000)
        #expect(scaled.height == 750)
        // 小图不放大
        let small = CaptureTestImages.solid(width: 100, height: 80)
        #expect(AnnotationEngine.scaleDown(small, maxPixel: 1000).width == 100)
    }
}

@Suite("OCREngine")
struct OCREngineTests {
    @Test func recognizesEnglishText() async throws {
        let image = CaptureTestImages.textImage("HELLO ONEDISK", width: 1000, height: 220)
        let result = try await OCREngine.recognizeText(in: image, languages: ["en-US"], minimumConfidence: 0.2)
        #expect(!result.observations.isEmpty)
        let normalized = result.fullText.uppercased().replacingOccurrences(of: " ", with: "")
        #expect(normalized.contains("HELLO"), "OCR 结果应包含 HELLO，实际: \(result.fullText)")
    }

    @Test func detectsEmptyImageAsNoText() async throws {
        let image = CaptureTestImages.solid(width: 100, height: 100)
        let result = try await OCREngine.recognizeText(in: image)
        #expect(result.observations.isEmpty)
    }

    @Test func barcodeDetectionOnPlainImageReturnsEmpty() async throws {
        let image = CaptureTestImages.solid(width: 200, height: 200)
        let barcodes = try await OCREngine.detectBarcodes(in: image)
        #expect(barcodes.isEmpty)
    }
}

@Suite("CaptureStore")
struct CaptureStoreTests {
    private func makeStore() async throws -> CaptureStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = Database(url: dir.appendingPathComponent("t.sqlite"))
        try await db.open()
        try await db.migrate(DeskvanicSchema.migrations + [CaptureSchema.migration])
        return CaptureStore(database: db, index: SearchIndex(database: db))
    }

    @Test func addRecentUpdateDelete() async throws {
        let store = try await makeStore()
        let record = CaptureRecord(filePath: "/tmp/a.png", kind: "region")
        try await store.add(record)
        var records = try await store.recent()
        #expect(records.count == 1 && records[0].id == record.id)

        try await store.updateOCR(id: record.id, ocrText: "识别到的文本", barcodes: ["https://x.com"])
        records = try await store.recent()
        #expect(records[0].ocrText == "识别到的文本")
        #expect(records[0].barcodePayloads == ["https://x.com"])

        try await store.delete(id: record.id)
        #expect(try await store.recent().isEmpty)
    }

    @Test func ocrTextIndexedForFullTextSearch() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-capidx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = Database(url: dir.appendingPathComponent("t.sqlite"))
        try await db.open()
        try await db.migrate(DeskvanicSchema.migrations + [CaptureSchema.migration])
        let index = SearchIndex(database: db)
        let store = CaptureStore(database: db, index: index)

        let record = CaptureRecord(filePath: "/tmp/b.png", kind: "window")
        try await store.add(record)
        try await store.updateOCR(id: record.id, ocrText: "会议纪要 关键内容", barcodes: [])
        let hits = try await index.search("会议纪要")
        #expect(hits.contains { $0.type == "capture" && $0.ref == record.id })
        try await store.delete(id: record.id)
        #expect(try await index.search("会议纪要").isEmpty)
    }
}
