import Foundation
import PDFKit
import Testing
import DeskvanicCore
@testable import DeskvanicFileStudio

@Suite("PDFEngine")
struct PDFEngineTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePDF(pages: Int, in dir: URL, name: String) throws -> URL {
        let doc = PDFDocument()
        for i in 0..<pages {
            let page = PDFPage()
            doc.insert(page, at: i)
        }
        let url = dir.appendingPathComponent(name)
        try doc.dataRepresentation()!.write(to: url)
        return url
    }

    @Test func mergeCombinesPageCounts() throws {
        let dir = try makeTempDir()
        let a = try makePDF(pages: 3, in: dir, name: "a.pdf")
        let b = try makePDF(pages: 2, in: dir, name: "b.pdf")
        let output = try PDFEngine.merge(sources: [a, b], destinationDirectory: dir)
        let merged = PDFDocument(url: output)
        #expect(merged?.pageCount == 5)
    }

    @Test func mergeRejectsSingleFile() throws {
        let dir = try makeTempDir()
        let a = try makePDF(pages: 1, in: dir, name: "a.pdf")
        #expect(throws: DeskvanicError.self) {
            try PDFEngine.merge(sources: [a], destinationDirectory: dir)
        }
    }

    @Test func splitProducesOneFilePerPage() throws {
        let dir = try makeTempDir()
        let source = try makePDF(pages: 4, in: dir, name: "book.pdf")
        let outputs = try PDFEngine.splitPages(source: source, destinationDirectory: dir)
        #expect(outputs.count == 4)
        for (index, output) in outputs.enumerated() {
            let doc = PDFDocument(url: output)
            #expect(doc?.pageCount == 1)
            #expect(output.lastPathComponent.contains("第\(index + 1)页"))
        }
    }

    @Test func extractValidatesPageRange() throws {
        let dir = try makeTempDir()
        let source = try makePDF(pages: 3, in: dir, name: "src.pdf")
        // 超范围报错
        #expect(throws: DeskvanicError.self) {
            try PDFEngine.extractPages(source: source, pages: [1, 9], destinationDirectory: dir)
        }
        let output = try PDFEngine.extractPages(source: source, pages: [3, 1], destinationDirectory: dir)
        let doc = PDFDocument(url: output)
        #expect(doc?.pageCount == 2)
    }

    @Test func rotateAllPages() throws {
        let dir = try makeTempDir()
        let source = try makePDF(pages: 2, in: dir, name: "r.pdf")
        let output = try PDFEngine.rotate(source: source, pages: [], degrees: 90, destinationDirectory: dir)
        let doc = PDFDocument(url: output)
        for i in 0..<doc!.pageCount {
            #expect(doc?.page(at: i)?.rotation == 90)
        }
        // 非法角度
        #expect(throws: DeskvanicError.self) {
            try PDFEngine.rotate(source: source, pages: [], degrees: 45, destinationDirectory: dir)
        }
    }

    @Test func optimizeReportsSizesHonestly() throws {
        let dir = try makeTempDir()
        // 生成含位图内容的 PDF（体积更可能被压缩）
        let doc = PDFDocument()
        for _ in 0..<3 {
            let image = CaptureLikeImages.noiseImage(width: 800, height: 600)
            if let page = PDFPage(image: NSImage(cgImage: image, size: CGSize(width: 800, height: 600))) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        let source = dir.appendingPathComponent("big.pdf")
        try doc.dataRepresentation()!.write(to: source)
        let originalBytes = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)

        let report = try PDFEngine.optimize(
            source: source, destinationDirectory: dir,
            jpegQuality: 0.5, scale: 0.8, targetBytes: nil)
        #expect(report.pageCount == 3)
        #expect(report.originalBytes == originalBytes)
        #expect(report.optimizedBytes > 0)
        #expect(!report.sideEffects.isEmpty)
        // 未指定目标时不谎报达成
        #expect(report.reachedTarget == true)
    }

    @Test func optimizeRejectsInvalidParameters() throws {
        let dir = try makeTempDir()
        let source = try makePDF(pages: 1, in: dir, name: "x.pdf")
        #expect(throws: DeskvanicError.self) {
            try PDFEngine.optimize(source: source, destinationDirectory: dir, jpegQuality: 2.0)
        }
        #expect(throws: DeskvanicError.self) {
            try PDFEngine.optimize(source: source, destinationDirectory: dir, scale: 0.1)
        }
    }
}

/// 与 Capture 测试类似的程序化图像生成（此处独立小实现避免跨测试依赖）。
enum CaptureLikeImages {
    static func noiseImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func random() -> CGFloat {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return CGFloat(seed % 1000) / 1000
        }
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor(CGColor(red: random(), green: random(), blue: random(), alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }
}

@Suite("BatchRenameEngine")
struct BatchRenameEngineTests {
    @Test func patternPlan() throws {
        let plan = try BatchRenameEngine.plan(
            fileNames: ["IMG_001.jpg", "IMG_002.jpg", "IMG_003.jpg"],
            mode: .pattern, patternBase: "旅行", startIndex: 1, padding: 3)
        #expect(plan.renames[0].to == "旅行-001.jpg")
        #expect(plan.renames[2].to == "旅行-003.jpg")
        #expect(!plan.isEmpty)
    }

    @Test func replacePlan() throws {
        let plan = try BatchRenameEngine.plan(
            fileNames: ["会议-记录-a.txt", "会议-记录-b.txt"],
            mode: .replace, find: "会议", replacement: "周会")
        #expect(plan.renames[0].to == "周会-记录-a.txt")
        #expect(plan.renames[1].to == "周会-记录-b.txt")
    }

    @Test func prefixSuffixKeepExtension() throws {
        let plan = try BatchRenameEngine.plan(
            fileNames: ["报告.pdf"], mode: .addPrefix, prefix: "2024-")
        #expect(plan.renames[0].to == "2024-报告.pdf")
        let plan2 = try BatchRenameEngine.plan(
            fileNames: ["报告.pdf"], mode: .addSuffix, suffix: "-终稿")
        #expect(plan2.renames[0].to == "报告-终稿.pdf")
    }

    @Test func detectsInternalCollisions() {
        // a.txt→x.txt、b.txt 不变：无冲突，正常返回
        #expect(throws: Never.self) {
            _ = try BatchRenameEngine.plan(
                fileNames: ["a.txt", "b.txt"],
                mode: .replace, find: "a", replacement: "x")
        }
        // 真正的内部冲突：两个文件替换后同名（a2→a1 与 a1 冲突）
        #expect(throws: DeskvanicError.self) {
            try BatchRenameEngine.plan(
                fileNames: ["a1.txt", "a2.txt"],
                mode: .replace, find: "2", replacement: "1")
        }
        // 空后缀被拒绝
        #expect(throws: DeskvanicError.self) {
            try BatchRenameEngine.plan(
                fileNames: ["文件.txt"],
                mode: .addSuffix, suffix: "")
        }
    }

    @Test func invalidPaddingRejected() {
        #expect(throws: DeskvanicError.self) {
            try BatchRenameEngine.plan(fileNames: ["a"], mode: .pattern, padding: 0)
        }
        #expect(throws: DeskvanicError.self) {
            try BatchRenameEngine.plan(fileNames: ["a"], mode: .pattern, padding: 7)
        }
    }
}
