import Foundation
import DeskvanicCore
import PDFKit
import Quartz

/// PDF 处理引擎：合并、拆分、旋转、页面提取、体积优化。
/// 全部操作"临时产物 → 校验 → 提交"，原文件只读不动。
public enum PDFEngine {

    // MARK: - 合并

    /// 按顺序合并多个 PDF。返回输出路径（目标目录内）。
    public static func merge(sources: [URL], destinationDirectory: URL, preferredName: String = "merged.pdf") throws -> URL {
        guard sources.count >= 2 else {
            throw DeskvanicError(.invalidInput, "合并至少需要两个 PDF 文件")
        }
        let merged = PDFDocument()
        var pageIndex = 0
        for source in sources {
            guard let doc = PDFDocument(url: source) else {
                throw DeskvanicError(.unsupportedFormat, "无法读取 PDF：\(source.lastPathComponent)")
            }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                merged.insert(page, at: pageIndex)
                pageIndex += 1
            }
        }
        guard merged.pageCount > 0 else {
            throw DeskvanicError(.outputValidationFailed, "合并结果为空")
        }
        return try write(merged, to: destinationDirectory, preferredName: preferredName)
    }

    // MARK: - 拆分

    /// 拆分为单页 PDF（每页一个文件），返回输出文件列表。
    public static func splitPages(source: URL, destinationDirectory: URL) throws -> [URL] {
        guard let doc = PDFDocument(url: source) else {
            throw DeskvanicError(.unsupportedFormat, "无法读取 PDF：\(source.lastPathComponent)")
        }
        guard doc.pageCount >= 1 else {
            throw DeskvanicError(.outputValidationFailed, "PDF 没有页面")
        }
        let stem = (source.lastPathComponent as NSString).deletingPathExtension
        var outputs: [URL] = []
        for i in 0..<doc.pageCount {
            let single = PDFDocument()
            guard let page = doc.page(at: i) else { continue }
            single.insert(page, at: 0)
            let output = try write(
                single, to: destinationDirectory,
                preferredName: "\(stem)-第\(i + 1)页.pdf")
            outputs.append(output)
        }
        return outputs
    }

    /// 提取指定页（1-based 页码数组）为新 PDF。
    public static func extractPages(source: URL, pages: [Int], destinationDirectory: URL) throws -> URL {
        guard let doc = PDFDocument(url: source) else {
            throw DeskvanicError(.unsupportedFormat, "无法读取 PDF：\(source.lastPathComponent)")
        }
        guard !pages.isEmpty else {
            throw DeskvanicError(.invalidInput, "未指定要提取的页码")
        }
        for page in pages where page < 1 || page > doc.pageCount {
            throw DeskvanicError(.invalidInput, "页码 \(page) 超出范围（1...\(doc.pageCount)）")
        }
        let extracted = PDFDocument()
        for (offset, pageNumber) in pages.enumerated() {
            guard let page = doc.page(at: pageNumber - 1) else { continue }
            extracted.insert(page, at: offset)
        }
        guard extracted.pageCount == pages.count else {
            throw DeskvanicError(.outputValidationFailed, "提取的页数与预期不符")
        }
        let stem = (source.lastPathComponent as NSString).deletingPathExtension
        return try write(extracted, to: destinationDirectory, preferredName: "\(stem)-提取.pdf")
    }

    // MARK: - 旋转

    /// 旋转指定页（1-based；角度为 90 的倍数）。
    @discardableResult
    public static func rotate(source: URL, pages: [Int], degrees: Int, destinationDirectory: URL) throws -> URL {
        guard [90, 180, 270, -90, -180, -270].contains(degrees) else {
            throw DeskvanicError(.invalidInput, "旋转角度必须是 90 的倍数")
        }
        guard let doc = PDFDocument(url: source) else {
            throw DeskvanicError(.unsupportedFormat, "无法读取 PDF：\(source.lastPathComponent)")
        }
        let validPages: [Int]
        if pages.isEmpty {
            validPages = Array(1...doc.pageCount)
        } else {
            for page in pages where page < 1 || page > doc.pageCount {
                throw DeskvanicError(.invalidInput, "页码 \(page) 超出范围（1...\(doc.pageCount)）")
            }
            validPages = pages
        }
        for pageNumber in validPages {
            guard let page = doc.page(at: pageNumber - 1) else { continue }
            page.rotation = (page.rotation + degrees).normalizedRotation
        }
        let stem = (source.lastPathComponent as NSString).deletingPathExtension
        return try write(doc, to: destinationDirectory, preferredName: "\(stem)-旋转.pdf")
    }

    // MARK: - 体积优化

    public struct OptimizeReport: Sendable {
        public let outputURL: URL
        public let originalBytes: Int64
        public let optimizedBytes: Int64
        /// 是否达成目标体积（未达成时如实标注，不谎报成功）。
        public let reachedTarget: Bool
        public let pageCount: Int
        /// 重渲染为位图后：文本不可选、注释丢失等影响说明。
        public let sideEffects: [String]
    }

    /// 体积优化：将页面重渲染为指定质量/缩放的位图后重建 PDF。
    /// 明确副作用：文本层变为位图（不可选中/搜索）、表单与注释丢失、书签丢失。
    /// 不承诺达到任意目标体积；达不到时如实报告。
    public static func optimize(
        source: URL,
        destinationDirectory: URL,
        jpegQuality: Double = 0.6,       // 0.05...1.0
        scale: Double = 1.0,             // 0.3...1.0
        targetBytes: Int64? = nil
    ) throws -> OptimizeReport {
        guard (0.05...1.0).contains(jpegQuality) else {
            throw DeskvanicError(.invalidInput, "JPEG 质量必须在 0.05...1.0")
        }
        guard (0.3...1.0).contains(scale) else {
            throw DeskvanicError(.invalidInput, "缩放比例必须在 0.3...1.0")
        }
        guard let doc = PDFDocument(url: source) else {
            throw DeskvanicError(.unsupportedFormat, "无法读取 PDF：\(source.lastPathComponent)")
        }
        let originalBytes = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)

        let optimized = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            guard let jpeg = NSBitmapImageRep(cgImage: cg).representation(
                using: .jpeg, properties: [.compressionFactor: jpegQuality]) else { continue }
            guard let pageImage = NSImage(data: jpeg),
                  let newPage = PDFPage(image: pageImage) else { continue }
            // 保持原页面尺寸（mediaBox），避免尺寸跳变
            newPage.setBounds(page.bounds(for: .mediaBox), for: .mediaBox)
            optimized.insert(newPage, at: optimized.pageCount)
        }
        guard optimized.pageCount == doc.pageCount else {
            throw DeskvanicError(.outputValidationFailed, "优化后页数不一致")
        }

        let stem = (source.lastPathComponent as NSString).deletingPathExtension
        let output = try write(optimized, to: destinationDirectory, preferredName: "\(stem)-优化.pdf")
        let optimizedBytes = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        try FileSafety.validateOutput(at: output)

        let reachedTarget = targetBytes == nil || optimizedBytes <= targetBytes!
        return OptimizeReport(
            outputURL: output, originalBytes: originalBytes, optimizedBytes: optimizedBytes,
            reachedTarget: reachedTarget, pageCount: doc.pageCount,
            sideEffects: [
                "页面内容转为位图：文本不可选中或搜索",
                "注释、表单域、书签与超链接会丢失",
                "含透明效果/矢量图形的页面体积可能反而增大",
            ])
    }

    // MARK: - 内部

    private static func write(_ doc: PDFDocument, to directory: URL, preferredName: String) throws -> URL {
        guard let data = doc.dataRepresentation() else {
            throw DeskvanicError(.fileWriteFailed, "PDF 序列化失败")
        }
        let output = FileSafety.uniqueDestination(in: directory, preferredName: preferredName)
        try data.write(to: output, options: .atomic)
        // 输出校验：可重新打开且页数一致
        guard let verify = PDFDocument(url: output), verify.pageCount == doc.pageCount else {
            try? FileManager.default.removeItem(at: output)
            throw DeskvanicError(.outputValidationFailed, "输出 PDF 校验失败，已清理残留文件")
        }
        return output
    }
}

extension Int {
    /// 归一化旋转角度到 0...350。
    var normalizedRotation: Int {
        let value = self % 360
        return value < 0 ? value + 360 : value
    }
}

/// 批量重命名引擎（纯函数，先预览后执行）。
public enum BatchRenameEngine {

    public enum Mode: String, Codable, Sendable, CaseIterable {
        case pattern      // 前缀+基础名+序号
        case replace      // 查找替换
        case addPrefix
        case addSuffix
    }

    public struct Plan: Sendable {
        /// (原文件名, 新文件名)
        public let renames: [(from: String, to: String)]
        public var isEmpty: Bool { renames.allSatisfy { $0.from == $0.to } }
    }

    /// 生成重命名计划（不执行）。文件名扩展保持不变（除 replace 显式修改）。
    public static func plan(
        fileNames: [String],
        mode: Mode,
        patternBase: String = "文件",
        find: String = "",
        replacement: String = "",
        prefix: String = "",
        suffix: String = "",
        startIndex: Int = 1,
        padding: Int = 2,
        keepExtension: Bool = true
    ) throws -> Plan {
        guard padding >= 1, padding <= 6 else {
            throw DeskvanicError(.invalidInput, "序号位数必须在 1...6")
        }
        var renames: [(from: String, to: String)] = []
        for (index, original) in fileNames.enumerated() {
            let ext = keepExtension ? (original as NSString).pathExtension : ""
            let stem = keepExtension ? (original as NSString).deletingPathExtension : original
            let counter = String(startIndex + index).padLeft(Int(padding))
            let newName: String
            switch mode {
            case .pattern:
                newName = ext.isEmpty ? "\(patternBase)-\(counter)" : "\(patternBase)-\(counter).\(ext)"
            case .replace:
                guard !find.isEmpty else {
                    throw DeskvanicError(.invalidInput, "查找内容不能为空")
                }
                let replaced = original.replacingOccurrences(of: find, with: replacement)
                newName = replaced.isEmpty ? original : replaced
            case .addPrefix:
                guard !prefix.isEmpty else {
                    throw DeskvanicError(.invalidInput, "前缀不能为空")
                }
                newName = ext.isEmpty ? prefix + original : prefix + original
            case .addSuffix:
                guard !suffix.isEmpty else {
                    throw DeskvanicError(.invalidInput, "后缀不能为空")
                }
                newName = ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
            }
            renames.append((original, newName))
        }

        // 新名称冲突检测：
        // 1) 两个条目改后同名 → 冲突
        // 2) 改名目标与某个"保持原名"的文件同名 → 冲突
        var targetCounts: [String: Int] = [:]
        for (_, to) in renames { targetCounts[to, default: 0] += 1 }
        for (from, to) in renames where to != from {
            if (targetCounts[to] ?? 0) > 1 {
                throw DeskvanicError(.invalidInput, "重命名后名称冲突：\(to)")
            }
            if renames.contains(where: { $0.from == to && $0.to == to }) {
                throw DeskvanicError(.invalidInput, "新名称与现有文件冲突：\(to)")
            }
        }
        return Plan(renames: renames)
    }
}

extension String {
    func padLeft(_ width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
