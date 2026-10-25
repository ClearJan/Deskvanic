import AppKit
import Foundation
import DeskvanicCapture
import DeskvanicCore
import DeskvanicFileStudio
import DeskvanicFlow
import DeskvanicQuickTools
import DeskvanicVault

/// 向 FlowEngine 注册真实业务动作（每个动作调用真正的模块实现，无演示逻辑）。
/// 输出目录统一使用用户"下载"目录（可在未来设置中自定义）。
@MainActor
enum FlowActions {
    nonisolated static var outputDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static func registerAll(into registry: ActionRegistry) {
        registerImageActions(registry)
        registerPDFActions(registry)
        registerZIPActions(registry)
        registerCaptureActions(registry)
        registerVaultActions(registry)
        registerTextActions(registry)
    }

    // MARK: - 图片

    private static func registerImageActions(_ registry: ActionRegistry) {
        registry.register(ActionDescriptor(
            id: "file.convertImage",
            name: "图片格式转换",
            module: "FileStudio",
            inputTypes: [.file],
            outputTypes: [.file],
            parameters: [
                ParameterDescriptor(key: "format", label: "目标格式", kind: .option,
                                    defaultValue: .string("jpeg"), allowedOptions: ["jpeg", "png", "heic", "tiff"]),
            ])) { context in
            guard let source = context.inputs.first?.filePayload else {
                return .failure(DeskvanicError(.invalidInput, "需要文件输入"))
            }
            let format = ImageEngine.Format(rawValue: context.stringParameter("format") ?? "jpeg") ?? .jpeg
            let report = try ImageEngine.convert(
                source: URL(fileURLWithPath: source), to: format,
                destinationDirectory: outputDirectory)
            return .success([ResourceRef(kind: .file, filePayload: report.outputURL.path)],
                            message: "已转换为 \(format.displayName)")
        }

        registry.register(ActionDescriptor(
            id: "file.resizeImage",
            name: "图片缩放",
            module: "FileStudio",
            inputTypes: [.file],
            outputTypes: [.file],
            parameters: [
                ParameterDescriptor(key: "maxPixel", label: "最长边像素", kind: .int,
                                    defaultValue: .int(1024), min: 16, max: 16384),
            ])) { context in
            guard let source = context.inputs.first?.filePayload else {
                return .failure(DeskvanicError(.invalidInput, "需要文件输入"))
            }
            let maxPixel = context.intParameter("maxPixel") ?? 1024
            let output = try ImageEngine.resize(
                source: URL(fileURLWithPath: source), maxPixel: maxPixel,
                destinationDirectory: outputDirectory)
            return .success([ResourceRef(kind: .file, filePayload: output.path)],
                            message: "已缩放至 ≤\(maxPixel)px")
        }

        registry.register(ActionDescriptor(
            id: "file.stripMetadata",
            name: "清除隐私元数据",
            module: "FileStudio",
            inputTypes: [.file],
            outputTypes: [.file],
            parameters: [])) { context in
            guard let source = context.inputs.first?.filePayload else {
                return .failure(DeskvanicError(.invalidInput, "需要文件输入"))
            }
            let output = try ImageEngine.stripMetadata(
                source: URL(fileURLWithPath: source), destinationDirectory: outputDirectory)
            return .success([ResourceRef(kind: .file, filePayload: output.path)], message: "GPS/IPTC 已剥离并复核")
        }
    }

    // MARK: - PDF

    private static func registerPDFActions(_ registry: ActionRegistry) {
        registry.register(ActionDescriptor(
            id: "file.pdfMerge",
            name: "PDF 合并",
            module: "FileStudio",
            inputTypes: [.files],
            outputTypes: [.pdf],
            parameters: [
                ParameterDescriptor(key: "name", label: "输出文件名", kind: .string, defaultValue: .string("merged.pdf")),
            ])) { context in
            let sources = context.inputs.compactMap(\.filePayload)
            guard sources.count >= 2 else {
                return .failure(DeskvanicError(.invalidInput, "合并至少需要两个 PDF（用文件集合输入）"))
            }
            let output = try PDFEngine.merge(
                sources: sources.map { URL(fileURLWithPath: $0) },
                destinationDirectory: outputDirectory,
                preferredName: context.stringParameter("name") ?? "merged.pdf")
            return .success([ResourceRef(kind: .pdf, filePayload: output.path)], message: "已合并 \(sources.count) 个文件")
        }

        registry.register(ActionDescriptor(
            id: "file.pdfSplit",
            name: "PDF 逐页拆分",
            module: "FileStudio",
            inputTypes: [.pdf],
            outputTypes: [.files],
            parameters: [])) { context in
            guard let source = context.inputs.first?.filePayload else {
                return .failure(DeskvanicError(.invalidInput, "需要 PDF 输入"))
            }
            let outputs = try PDFEngine.splitPages(
                source: URL(fileURLWithPath: source), destinationDirectory: outputDirectory)
            return .success(outputs.map { ResourceRef(kind: .pdf, filePayload: $0.path) },
                            message: "拆分为 \(outputs.count) 页")
        }
    }

    // MARK: - ZIP

    private static func registerZIPActions(_ registry: ActionRegistry) {
        registry.register(ActionDescriptor(
            id: "file.zipCreate",
            name: "打包 ZIP",
            module: "FileStudio",
            inputTypes: [.files],
            outputTypes: [.file],
            parameters: [
                ParameterDescriptor(key: "name", label: "归档名", kind: .string, defaultValue: .string("archive.zip")),
            ])) { context in
            let files = context.inputs.compactMap(\.filePayload)
            guard !files.isEmpty else {
                return .failure(DeskvanicError(.invalidInput, "需要文件集合输入"))
            }
            let destination = FileSafety.uniqueDestination(
                in: outputDirectory,
                preferredName: context.stringParameter("name") ?? "archive.zip")
            try ZIPArchive.createArchive(at: destination, adding: files.map { URL(fileURLWithPath: $0) })
            try FileSafety.validateOutput(at: destination)
            return .success([ResourceRef(kind: .file, filePayload: destination.path)], message: "已打包 \(files.count) 个文件")
        }

        registry.register(ActionDescriptor(
            id: "file.zipExtract",
            name: "解压 ZIP",
            module: "FileStudio",
            inputTypes: [.file],
            outputTypes: [.files],
            parameters: [])) { context in
            guard let source = context.inputs.first?.filePayload else {
                return .failure(DeskvanicError(.invalidInput, "需要 ZIP 文件输入"))
            }
            let extractDir = FileSafety.uniqueDestination(
                in: outputDirectory,
                preferredName: ((source as NSString).deletingPathExtension))
            let report = try ZIPArchive.extract(
                archiveAt: URL(fileURLWithPath: source), to: extractDir)
            let outputs = report.extracted.map { ResourceRef(kind: .file, filePayload: $0.path) }
            let rejectedNote = report.rejected.isEmpty ? "" : "（拒绝 \(report.rejected.count) 个危险条目）"
            return .success(outputs, message: "解压 \(outputs.count) 个文件\(rejectedNote)")
        }
    }

    // MARK: - OCR

    private static func registerCaptureActions(_ registry: ActionRegistry) {
        registry.register(ActionDescriptor(
            id: "image.ocr",
            name: "图片 OCR 识别",
            module: "Capture",
            inputTypes: [.file, .image],
            outputTypes: [.text],
            parameters: [])) { context in
            guard let source = context.inputs.first?.filePayload else {
                return .failure(DeskvanicError(.invalidInput, "需要图片文件输入"))
            }
            guard let image = NSImage(contentsOfFile: source)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return .failure(DeskvanicError(.unsupportedFormat, "无法解码图片：\(source)"))
            }
            let result = try await OCREngine.recognizeText(in: image)
            let text = result.fullText
            guard !text.isEmpty else {
                return .failure(DeskvanicError(.outputValidationFailed, "未识别到文本"))
            }
            return .success([ResourceRef(kind: .text, textPayload: text)], message: "识别 \(text.count) 字符")
        }

        registry.register(ActionDescriptor(
            id: "image.qrGenerate",
            name: "生成二维码图片",
            module: "QuickTools",
            inputTypes: [.text, .url],
            outputTypes: [.image],
            parameters: [])) { context in
            guard let payload = context.inputs.first?.textPayload ?? context.inputs.first?.urlPayload,
                  !payload.isEmpty else {
                return .failure(DeskvanicError(.invalidInput, "需要文本或 URL 输入"))
            }
            let image = try QRCodeService.generate(payload: payload)
            let url = FileSafety.uniqueDestination(in: outputDirectory, preferredName: "qrcode.png")
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                return .failure(DeskvanicError(.fileWriteFailed, "PNG 编码失败"))
            }
            try data.write(to: url, options: .atomic)
            try FileSafety.validateOutput(at: url)
            return .success([ResourceRef(kind: .image, filePayload: url.path)], message: "二维码已生成")
        }
    }

    // MARK: - 资料库

    private static func registerVaultActions(_ registry: ActionRegistry) {
        registry.register(ActionDescriptor(
            id: "vault.saveText",
            name: "文本存入资料库",
            module: "Vault",
            inputTypes: [.text],
            outputTypes: [.void],
            parameters: [
                ParameterDescriptor(key: "title", label: "标题", kind: .string, defaultValue: .string("工作流文本")),
            ])) { context in
            guard let text = context.inputs.first?.textPayload, !text.isEmpty else {
                return .failure(DeskvanicError(.invalidInput, "需要文本输入"))
            }
            let item = VaultItem(kind: .text, title: context.stringParameter("title") ?? "工作流文本",
                                 contentText: text, tags: ["工作流"])
            try await VaultServices.store.add(item)
            return .success([], message: "已存入资料库")
        }

        registry.register(ActionDescriptor(
            id: "vault.saveFile",
            name: "文件存入资料库（复制）",
            module: "Vault",
            inputTypes: [.file, .image, .pdf, .files],
            outputTypes: [.void],
            parameters: [])) { context in
            let files = context.inputs.compactMap(\.filePayload)
            guard !files.isEmpty else {
                return .failure(DeskvanicError(.invalidInput, "需要文件输入"))
            }
            var saved = 0
            for path in files {
                let url = URL(fileURLWithPath: path)
                let kind: VaultKind
                switch url.pathExtension.lowercased() {
                case "png", "jpg", "jpeg", "heic", "gif", "tiff", "webp": kind = .image
                case "pdf": kind = .pdf
                default: kind = .file
                }
                let itemDir = AppEnvironment.vaultStorageDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
                let dest = FileSafety.uniqueDestination(in: itemDir, preferredName: url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: dest)
                try FileSafety.validateOutput(at: dest)
                let item = VaultItem(kind: kind, title: url.deletingPathExtension().lastPathComponent,
                                     storagePath: dest.path, storageMode: .copied, tags: ["工作流"])
                try await VaultServices.store.add(item)
                saved += 1
            }
            return .success([], message: "已存入 \(saved) 个文件")
        }
    }

    // MARK: - 文本

    private static func registerTextActions(_ registry: ActionRegistry) {
        registry.register(ActionDescriptor(
            id: "text.clean",
            name: "文本清理",
            module: "QuickTools",
            inputTypes: [.text],
            outputTypes: [.text],
            parameters: [])) { context in
            guard var text = context.inputs.first?.textPayload else {
                return .failure(DeskvanicError(.invalidInput, "需要文本输入"))
            }
            text = TextToolkit.clean(text, options: [.fullWidthToHalf, .trimTrailingWhitespace, .collapseBlankLines, .joinCJKLines])
            return .success([ResourceRef(kind: .text, textPayload: text)])
        }

        registry.register(ActionDescriptor(
            id: "text.linesDedupe",
            name: "文本去重排序",
            module: "QuickTools",
            inputTypes: [.text],
            outputTypes: [.text],
            parameters: [
                ParameterDescriptor(key: "sort", label: "自然排序", kind: .bool, defaultValue: .bool(false)),
            ])) { context in
            guard let text = context.inputs.first?.textPayload else {
                return .failure(DeskvanicError(.invalidInput, "需要文本输入"))
            }
            var lines = TextToolkit.LineOperation.deduplicate.apply(text.components(separatedBy: "\n"))
            if context.boolParameter("sort") == true {
                lines = TextToolkit.LineOperation.sortNatural.apply(lines)
            }
            return .success([ResourceRef(kind: .text, textPayload: lines.joined(separator: "\n"))])
        }
    }
}
