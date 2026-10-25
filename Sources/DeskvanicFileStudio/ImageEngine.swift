import CoreGraphics
import Foundation
import ImageIO
import DeskvanicCore
import UniformTypeIdentifiers

/// 图片处理引擎：转换/缩放/压缩/元数据（ImageIO，本地执行）。
/// 所有操作保留原文件，输出经"临时→校验→提交"。
public enum ImageEngine {

    public enum Format: String, CaseIterable, Sendable {
        case jpeg, png, heic, tiff

        public var utType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            case .heic: return UTType("public.heic") ?? .jpeg
            case .tiff: return .tiff
            }
        }

        public var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            default: return rawValue
            }
        }
        public var displayName: String { rawValue.uppercased() }
    }

    public struct ConvertReport: Sendable {
        public let outputURL: URL
        public let pixelWidth: Int
        public let pixelHeight: Int
        /// 动图/GIF 转换只取第一帧时如实标注。
        public let pagesConverted: Int
        public let totalPages: Int
        public let notes: [String]
    }

    // MARK: - 读取

    static func openSource(_ url: URL) throws -> CGImageSource {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DeskvanicError(.fileNotFound, "文件不存在：\(url.lastPathComponent)")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DeskvanicError(.fileUnreadable, "无法读取文件：\(url.lastPathComponent)")
        }
        guard let type = CGImageSourceGetType(source), (type as String) != "" else {
            throw DeskvanicError(.unsupportedFormat, "不是有效的图片文件：\(url.lastPathComponent)")
        }
        return source
    }

    /// 读取元数据。
    public struct Metadata: Codable, Sendable {
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let dpiWidth: Double
        public let dpiHeight: Double
        public let colorSpace: String
        public let bitsPerComponent: Int
        public let hasAlpha: Bool
        public let format: String
        public let fileSizeBytes: Int
        public let pageTotal: Int
        public let hasEXIF: Bool
        public let hasGPS: Bool
        public let hasIPTC: Bool
        public let hasXMP: Bool
    }

    public static func inspect(source url: URL) throws -> Metadata {
        let source = try openSource(url)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw DeskvanicError(.unsupportedFormat, "无法读取图片属性：\(url.lastPathComponent)")
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else {
            throw DeskvanicError(.unsupportedFormat, "图片尺寸无效：\(url.lastPathComponent)")
        }
        let containerProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let pageCount = containerProps[kCGImagePropertyImageCount] as? Int ?? 1

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]

        let formatRaw = CGImageSourceGetType(source) as String? ?? ""
        return Metadata(
            pixelWidth: width, pixelHeight: height,
            dpiWidth: props[kCGImagePropertyDPIWidth] as? Double ?? 72,
            dpiHeight: props[kCGImagePropertyDPIHeight] as? Double ?? 72,
            colorSpace: (props[kCGImagePropertyColorModel] as? String) ?? "RGB",
            bitsPerComponent: props[kCGImagePropertyDepth] as? Int ?? 8,
            hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false,
            format: formatRaw,
            fileSizeBytes: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0,
            pageTotal: pageCount,
            hasEXIF: !(exif ?? [:]).isEmpty,
            hasGPS: !(gps ?? [:]).isEmpty,
            hasIPTC: !(iptc ?? [:]).isEmpty,
            hasXMP: false)  // XMP 探测在 Swift ImageIO overlay 不可用；GPS/EXIF/IPTC 为隐私验证主体
    }

    // MARK: - 格式转换

    public static func convert(
        source: URL, to format: Format, destinationDirectory: URL,
        quality: Double = 0.85
    ) throws -> ConvertReport {
        guard (0.05...1.0).contains(quality) else {
            throw DeskvanicError(.invalidInput, "质量参数必须在 0.05...1.0")
        }
        let imageSource = try openSource(source)
        let metadata = try inspect(source: source)
        var notes: [String] = []

        guard let firstImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else {
            throw DeskvanicError(.unsupportedFormat, "图片解码失败：\(source.lastPathComponent)")
        }
        if metadata.pageTotal > 1 {
            notes.append("原图含 \(metadata.pageTotal) 页/帧，仅转换第 1 页")
        }

        // GIF/动图转静态格式的说明
        let sourceType = (CGImageSourceGetType(imageSource) as String? ?? "").lowercased()
        if sourceType.contains("gif") {
            notes.append("动图（GIF）只保留第一帧")
        }

        let output = FileSafety.uniqueDestination(
            in: destinationDirectory,
            preferredName: ((source.lastPathComponent as NSString).deletingPathExtension)
                + "." + format.fileExtension)

        let dest = CGImageDestinationCreateWithURL(
            output as CFURL, format.utType.identifier as CFString, 1, nil)
        guard let dest else {
            throw DeskvanicError(.fileWriteFailed, "无法创建输出文件（\(format.displayName) 编码器不可用）")
        }
        var destProps: [CFString: Any] = [:]
        if format == .jpeg || format == .heic {
            destProps[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, firstImage, destProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: output)
            throw DeskvanicError(.fileWriteFailed, "\(format.displayName) 编码失败")
        }

        // 输出校验：重新打开，页数 ≥ 1
        try FileSafety.validateOutput(at: output)
        let verifySource = try openSource(output)
        guard let verifyProps = CGImageSourceCopyPropertiesAtIndex(verifySource, 0, nil) as? [CFString: Any],
              let verifyWidth = verifyProps[kCGImagePropertyPixelWidth] as? Int,
              let verifyHeight = verifyProps[kCGImagePropertyPixelHeight] as? Int,
              verifyWidth > 0, verifyHeight > 0 else {
            try? FileManager.default.removeItem(at: output)
            throw DeskvanicError(.outputValidationFailed, "输出图片校验失败，已清理")
        }
        if verifyWidth != metadata.pixelWidth || verifyHeight != metadata.pixelHeight {
            notes.append("输出尺寸 \(verifyWidth)×\(verifyHeight) 与原图 \(metadata.pixelWidth)×\(metadata.pixelHeight) 不同")
        }
        return ConvertReport(
            outputURL: output,
            pixelWidth: verifyWidth, pixelHeight: verifyHeight,
            pagesConverted: 1, totalPages: metadata.pageTotal, notes: notes)
    }

    // MARK: - 尺寸调整

    /// 等比缩放到最大边长（高质量重采样）。allowUpscale=false 且原图更小时直接复制。
    public static func resize(
        source: URL, maxPixel: Int, destinationDirectory: URL, allowUpscale: Bool = false
    ) throws -> URL {
        guard (8...16384).contains(maxPixel) else {
            throw DeskvanicError(.invalidInput, "目标尺寸必须在 8...16384 像素")
        }
        let imageSource = try openSource(source)
        let metadata = try inspect(source: source)
        let maxSide = max(metadata.pixelWidth, metadata.pixelHeight)
        if maxSide <= maxPixel && !allowUpscale {
            // 不放大：复制原文件
            let output = FileSafety.uniqueDestination(
                in: destinationDirectory, preferredName: source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: output)
            return output
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let resized = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw DeskvanicError(.fileWriteFailed, "缩放失败")
        }
        return try writeCGImage(resized, sourceName: source.lastPathComponent,
                                to: destinationDirectory, format: .png, quality: nil,
                                expectedWidth: resized.width, expectedHeight: resized.height)
    }

    // MARK: - 压缩

    public struct CompressReport: Sendable {
        public let outputURL: URL
        public let originalBytes: Int64
        public let achievedBytes: Int64
        public let reachedTarget: Bool
        /// PNG 无质量参数时给出格式建议。
        public let suggestion: String?
    }

    /// 二分质量逼近目标体积（最多 8 次迭代）；PNG 无质量参数，无法逼近时如实报告。
    public static func compress(
        source: URL, targetBytes: Int64, destinationDirectory: URL
    ) throws -> CompressReport {
        guard targetBytes > 0 else {
            throw DeskvanicError(.invalidInput, "目标体积必须为正")
        }
        let metadata = try inspect(source: source)
        let originalBytes = Int64(metadata.fileSizeBytes)
        let imageSource = try openSource(source)
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw DeskvanicError(.unsupportedFormat, "图片解码失败")
        }

        let isPNG = (CGImageSourceGetType(imageSource) as String? ?? "").contains("png")
        if isPNG {
            // PNG 无损：无法用质量参数逼近目标
            let output = try writeCGImage(image, sourceName: source.lastPathComponent,
                                          to: destinationDirectory, format: .png, quality: nil,
                                          expectedWidth: metadata.pixelWidth, expectedHeight: metadata.pixelHeight)
            let achieved = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return CompressReport(
                outputURL: output, originalBytes: originalBytes, achievedBytes: achieved,
                reachedTarget: achieved <= targetBytes,
                suggestion: achieved > targetBytes
                    ? "PNG 为无损格式，无法通过质量参数压缩；建议转 JPEG 或 HEIC 后再压缩。" : nil)
        }

        // 有损格式：二分质量
        var low = 0.05, high = 0.95
        var best: (url: URL, bytes: Int64)?
        for iteration in 0..<8 {
            let mid = (low + high) / 2
            let output = try writeCGImage(image, sourceName: source.lastPathComponent,
                                          to: destinationDirectory, format: .jpeg, quality: mid,
                                          expectedWidth: metadata.pixelWidth, expectedHeight: metadata.pixelHeight,
                                          keepTemp: true)
            let bytes = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if bytes <= targetBytes {
                // 旧 best 已被更高质量结果取代时删除，避免临时文件泄漏（审计 #2）
                if let oldBest = best {
                    try? FileManager.default.removeItem(at: oldBest.url)
                }
                best = (output, bytes)
                low = mid  // 还可以更高质量
            } else {
                high = mid
                try? FileManager.default.removeItem(at: output)
            }
            _ = iteration
        }
        guard var final = best else {
            throw DeskvanicError(
                .outputValidationFailed,
                "即使最低质量也达不到目标体积（原图 \(originalBytes.formatted(.byteCount(style: .memory)))），未产出文件",
                recovery: "请放宽目标体积，或先缩小图片尺寸。")
        }
        // 最终命名
        let finalURL = FileSafety.uniqueDestination(
            in: destinationDirectory,
            preferredName: ((source.lastPathComponent as NSString).deletingPathExtension) + "-compressed.jpg")
        try? FileManager.default.moveItem(at: final.url, to: finalURL)
        final.url = finalURL
        try FileSafety.validateOutput(at: finalURL)
        return CompressReport(
            outputURL: finalURL, originalBytes: originalBytes, achievedBytes: final.bytes,
            reachedTarget: final.bytes <= targetBytes, suggestion: nil)
    }

    // MARK: - 元数据剥离

    /// 剥离用户数据元数据：GPS 定位、EXIF 拍摄信息、IPTC。
    /// 说明：ImageIO 会为 JPEG 自动写入仅含创建时间的基础 EXIF（无位置/设备信息），
    /// 该部分不属于用户隐私数据；如需零 EXIF，请转换为 PNG。
    /// 输出后重新校验 GPS/IPTC 确实不存在（隐私承诺必须验证）。
    public static func stripMetadata(
        source: URL, destinationDirectory: URL, keepOrientation: Bool = true
    ) throws -> URL {
        let imageSource = try openSource(source)
        let metadata = try inspect(source: source)

        // 读取像素（含方向 bake：kCGImageSourceCreateThumbnailWithTransform 会应用 EXIF 方向）
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: keepOrientation,
            kCGImageSourceThumbnailMaxPixelSize: max(metadata.pixelWidth, metadata.pixelHeight),
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw DeskvanicError(.fileWriteFailed, "解码失败")
        }

        let ext = (source.lastPathComponent as NSString).pathExtension.lowercased()
        let format: Format
        switch ext {
        case "png": format = .png
        case "heic": format = .heic
        case "tiff", "tif": format = .tiff
        default: format = .jpeg
        }

        let output = try writeCGImage(
            image, sourceName: source.lastPathComponent, to: destinationDirectory,
            format: format, quality: 0.9,
            expectedWidth: keepOrientation && metadata.pixelWidth != metadata.pixelHeight
                ? nil : metadata.pixelWidth,
            expectedHeight: nil)

        // 隐私验证：输出必须不含 GPS/IPTC（EXIF 中仅允许 JPEG 自动生成的基础时间信息）
        let verify = try inspect(source: output)
        if verify.hasGPS || verify.hasIPTC {
            try? FileManager.default.removeItem(at: output)
            throw DeskvanicError(
                .outputValidationFailed,
                "隐私校验失败：输出仍含定位/版权元数据（GPS: \(verify.hasGPS), IPTC: \(verify.hasIPTC)），已清理",
                recovery: "请反馈此问题。")
        }
        return output
    }

    // MARK: - 内部

    private static func writeCGImage(
        _ image: CGImage, sourceName: String, to directory: URL, format: Format,
        quality: Double?, expectedWidth: Int?, expectedHeight: Int?,
        keepTemp: Bool = false
    ) throws -> URL {
        let output = keepTemp
            ? directory.appendingPathComponent(".compress-\(UUID().uuidString).jpg")
            : FileSafety.uniqueDestination(
                in: directory,
                preferredName: ((sourceName as NSString).deletingPathExtension) + ".\(format.fileExtension)")
        guard let dest = CGImageDestinationCreateWithURL(
            output as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw DeskvanicError(.fileWriteFailed, "无法创建输出（\(format.displayName)）")
        }
        var props: [CFString: Any] = [:]
        if let quality, format == .jpeg || format == .heic {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: output)
            throw DeskvanicError(.fileWriteFailed, "\(format.displayName) 编码失败")
        }
        try FileSafety.validateOutput(at: output)

        // 尺寸校验
        if let expectedWidth, let expectedHeight {
            let verify = try inspect(source: output)
            if verify.pixelWidth != expectedWidth || verify.pixelHeight != expectedHeight {
                try? FileManager.default.removeItem(at: output)
                throw DeskvanicError(
                    .outputValidationFailed,
                    "输出尺寸 \(verify.pixelWidth)×\(verify.pixelHeight) 与预期 \(expectedWidth)×\(expectedHeight) 不符，已清理")
            }
        }
        return output
    }
}
