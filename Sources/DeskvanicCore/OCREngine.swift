import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import DeskvanicCore
import Vision

/// 本地 OCR 引擎（Vision 框架，全部在本机执行，无网络上传）。
/// 中英文混排识别；结果按置信度过滤。
public enum OCREngine {

    public struct TextObservation: Sendable, Equatable {
        public let text: String
        public let confidence: Double
        public let boundingBox: CGRect   // 归一化坐标（左下原点）
    }

    public struct OCRResult: Sendable, Equatable {
        public let observations: [TextObservation]
        /// 依阅读顺序拼接的完整文本。
        public var fullText: String {
            observations.map(\.text).joined(separator: "\n")
        }
    }

    /// 识别图片中的文本。
    /// - Parameters:
    ///   - languages: 识别语言偏好（如 ["zh-Hans", "en-US"]）
    ///   - minimumConfidence: 低于该置信度的结果丢弃（0...1）
    public static func recognizeText(
        in image: CGImage,
        languages: [String] = ["zh-Hans", "en-US"],
        minimumConfidence: Double = 0.3
    ) async throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations = (request.results ?? []).compactMap { observation -> TextObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let confidence = Double(candidate.confidence)
            guard confidence >= minimumConfidence else { return nil }
            return TextObservation(
                text: candidate.string,
                confidence: confidence,
                boundingBox: observation.boundingBox)
        }
        return OCRResult(observations: observations)
    }

    /// 条码/二维码识别（Vision）。
    public static func detectBarcodes(in image: CGImage) async throws -> [String] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }
}

/// 标注引擎：纯函数图像合成——裁剪、矩形、箭头、文字、真像素模糊。
/// 所有操作返回新 CGImage，不改原图。模糊是真正破坏性像素处理（CIGaussianBlur），
/// 不是覆盖图层，满足"隐私遮盖后不可恢复"的要求。
public enum AnnotationEngine {

    // MARK: - 裁剪

    /// 按像素矩形裁剪（坐标为图像像素空间，自动夹紧到图像边界）。
    public static func crop(_ image: CGImage, rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = rect.intersection(bounds)
        guard !clamped.isEmpty, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return image.cropping(to: clamped)
    }

    // MARK: - 模糊（破坏性）

    /// 对指定像素区域应用高斯模糊（真像素破坏，用于隐私遮盖）。
    /// 区域外的像素保持不变；半径 1...64。
    public static func blurRegion(_ image: CGImage, rect: CGRect, radius: Double = 12) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1,
              radius >= 1, radius <= 64,
              let context = createContext(width: image.width, height: image.height) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = rect.intersection(bounds)
        guard !clamped.isEmpty else { return nil }

        // 1. 先整体画原图
        context.draw(image, in: bounds)

        // 2. 取出区域 → CIFilter 高斯模糊 → 回画
        guard let regionImage = image.cropping(to: clamped) else { return nil }
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        let ciImage = CIImage(cgImage: regionImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        // 收敛边界，避免模糊边缘透明化
        let clampedOutput = output.clampedToExtent()
            .cropped(to: CGRect(x: 0, y: 0, width: regionImage.width, height: regionImage.height))
        guard let blurred = ciContext.createCGImage(clampedOutput, from: clampedOutput.extent) else { return nil }

        context.saveGState()
        context.clip(to: clamped)
        context.draw(blurred, in: clamped)
        context.restoreGState()

        return context.makeImage()
    }

    // MARK: - 矩形框

    /// 在像素坐标绘制矩形描边。
    public static func drawRect(
        _ image: CGImage, rect: CGRect,
        color: CGColor = CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 1),
        lineWidth: CGFloat = 4
    ) -> CGImage? {
        guard let context = createContext(width: image.width, height: image.height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.stroke(rect)
        return context.makeImage()
    }

    // MARK: - 箭头

    /// 从 start 到 end 绘制带箭头的线段（像素坐标）。
    public static func drawArrow(
        _ image: CGImage, start: CGPoint, end: CGPoint,
        color: CGColor = CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 1),
        lineWidth: CGFloat = 4
    ) -> CGImage? {
        guard let context = createContext(width: image.width, height: image.height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(lineWidth)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        // 主线
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        // 箭头头部
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = max(14, lineWidth * 4)
        let spread: CGFloat = 0.42  // 约 24°
        let p1 = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread))
        let p2 = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread))
        context.move(to: p1)
        context.addLine(to: end)
        context.addLine(to: p2)
        context.closePath()
        context.fillPath()

        return context.makeImage()
    }

    // MARK: - 文字

    /// 在像素坐标绘制文字标注（NSFont，坐标为文字左上角）。
    public static func drawText(
        _ image: CGImage, text: String, at point: CGPoint,
        color: CGColor = CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 1),
        fontSize: CGFloat = 28
    ) -> CGImage? {
        guard !text.isEmpty, let context = createContext(width: image.width, height: image.height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(color)

        let nsColor = NSColor(cgColor: color) ?? .red
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: nsColor]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)

        context.textPosition = CGPoint(x: point.x, y: CGFloat(image.height) - point.y - fontSize)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    // MARK: - 缩放

    /// 等比缩放到最大边长（用于导出前缩小大图）。
    public static func scaleDown(_ image: CGImage, maxPixel: Int) -> CGImage {
        let maxSide = max(image.width, image.height)
        guard maxPixel >= 16, maxSide > maxPixel else { return image }
        let scale = CGFloat(maxPixel) / CGFloat(maxSide)
        let newWidth = max(1, Int(CGFloat(image.width) * scale))
        let newHeight = max(1, Int(CGFloat(image.height) * scale))
        guard let context = createContext(width: newWidth, height: newHeight) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }

    // MARK: - 内部

    private static func createContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
