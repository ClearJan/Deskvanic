import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import DeskvanicCore

/// 二维码生成与解析（CoreImage，本地执行）。
public enum QRCodeService {

    // MARK: - 生成

    /// 生成二维码 CGImage。scale 为每模块像素（1...32）。
    public static func generate(
        payload: String,
        scale: Int = 8,
        correctionLevel: String = "M"
    ) throws -> CGImage {
        guard !payload.isEmpty else {
            throw DeskvanicError(.invalidInput, "二维码内容不能为空")
        }
        guard (1...32).contains(scale) else {
            throw DeskvanicError(.invalidInput, "scale 必须在 1...32")
        }
        guard ["L", "M", "Q", "H"].contains(correctionLevel) else {
            throw DeskvanicError(.invalidInput, "纠错级别必须是 L/M/Q/H")
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = correctionLevel

        guard let output = filter.outputImage else {
            throw DeskvanicError(.externalService, "二维码生成失败")
        }
        let transformed = output.transformed(
            by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let image = context.createCGImage(transformed, from: transformed.extent) else {
            throw DeskvanicError(.externalService, "二维码渲染失败")
        }
        return image
    }

    // MARK: - 解析

    public struct Payload: Equatable, Sendable {
        public let content: String
        public let isURL: Bool
        public let urlScheme: String?
    }

    /// 解析图中的二维码/条码，返回全部识别结果。
    public static func detect(in image: CGImage) throws -> [Payload] {
        let ciImage = CIImage(cgImage: image)
        guard let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
            throw DeskvanicError(.externalService, "无法创建二维码检测器")
        }
        let features = detector.features(in: ciImage)
        return features.compactMap { feature in
            guard let qrFeature = feature as? CIQRCodeFeature,
                  let message = qrFeature.messageString else { return nil }
            return makePayload(message)
        }
    }

    static func makePayload(_ message: String) -> Payload {
        if let url = URL(string: message),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp"].contains(scheme) {
            return Payload(content: message, isURL: true, urlScheme: scheme)
        }
        // javascript:/data: 等危险 scheme 不标记为 URL，按纯文本处理
        return Payload(content: message, isURL: false, urlScheme: nil)
    }
}
