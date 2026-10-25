import CoreGraphics
import Foundation
import DeskvanicCore

/// 颜色工具：hex / RGB / HSV / HSL 互转与格式化（全部纯函数）。
public enum ColorToolkit {

    public struct RGBA: Equatable, Sendable {
        public var red: Double      // 0...255
        public var green: Double
        public var blue: Double
        public var alpha: Double    // 0...1

        public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    public struct HSV: Equatable, Sendable {
        public var hue: Double        // 0...360
        public var saturation: Double // 0...1
        public var value: Double      // 0...1

        public init(hue: Double, saturation: Double, value: Double) {
            self.hue = hue
            self.saturation = saturation
            self.value = value
        }
    }

    public struct HSL: Equatable, Sendable {
        public var hue: Double
        public var saturation: Double
        public var lightness: Double

        public init(hue: Double, saturation: Double, lightness: Double) {
            self.hue = hue
            self.saturation = saturation
            self.lightness = lightness
        }
    }

    // MARK: - Hex 解析

    /// 解析 #RGB / #RRGGBB / #RRGGBBAA / RRGGBB。
    public static func parseHex(_ hex: String) throws -> RGBA {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.allSatisfy({ $0.isHexDigit }) else {
            throw DeskvanicError(.invalidInput, "hex 颜色包含非法字符：\(hex)")
        }
        let channel: (String) -> Double = { hexPair in
            Double(Int(hexPair, radix: 16) ?? 0) * (hexPair.count == 1 ? 17.0 : 1.0)
        }
        switch text.count {
        case 3:
            let parts = text.map { String($0) }
            return RGBA(
                red: channel(parts[0]), green: channel(parts[1]),
                blue: channel(parts[2]), alpha: 1)
        case 6:
            return RGBA(
                red: channel(String(text.prefix(2))),
                green: channel(String(text.dropFirst(2).prefix(2))),
                blue: channel(String(text.dropFirst(4))),
                alpha: 1)
        case 8:
            return RGBA(
                red: channel(String(text.prefix(2))),
                green: channel(String(text.dropFirst(2).prefix(2))),
                blue: channel(String(text.dropFirst(4).prefix(2))),
                alpha: channel(String(text.dropFirst(6))) / 255)
        default:
            throw DeskvanicError(.invalidInput, "hex 颜色长度必须是 3/6/8 位：\(hex)")
        }
    }

    public static func toHex(_ color: RGBA, includeAlpha: Bool = false) -> String {
        func hex(_ value: Double) -> String {
            String(format: "%02X", Int(value.rounded().clamped(0...255)))
        }
        var output = "#" + hex(color.red) + hex(color.green) + hex(color.blue)
        if includeAlpha {
            output += hex(color.alpha * 255)
        }
        return output
    }

    // MARK: - RGB ↔ HSV

    public static func rgbToHSV(_ color: RGBA) -> HSV {
        let r = color.red / 255, g = color.green / 255, b = color.blue / 255
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        var hue: Double = 0
        if delta > 0 {
            if maxV == r {
                hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                hue = 60 * ((b - r) / delta + 2)
            } else {
                hue = 60 * ((r - g) / delta + 4)
            }
            if hue < 0 { hue += 360 }
        }
        return HSV(
            hue: hue,
            saturation: maxV == 0 ? 0 : delta / maxV,
            value: maxV)
    }

    public static func hsvToRGB(_ hsv: HSV) -> RGBA {
        let c = hsv.value * hsv.saturation
        let x = c * (1 - abs((hsv.hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = hsv.value - c
        let (r, g, b): (Double, Double, Double)
        switch hsv.hue {
        case 0..<60: (r, g, b) = (c, x, 0)
        case 60..<120: (r, g, b) = (x, c, 0)
        case 120..<180: (r, g, b) = (0, c, x)
        case 180..<240: (r, g, b) = (0, x, c)
        case 240..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return RGBA(red: (r + m) * 255, green: (g + m) * 255, blue: (b + m) * 255, alpha: 1)
    }

    // MARK: - RGB ↔ HSL

    public static func rgbToHSL(_ color: RGBA) -> HSL {
        let r = color.red / 255, g = color.green / 255, b = color.blue / 255
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        let lightness = (maxV + minV) / 2
        var hue: Double = 0
        var saturation: Double = 0
        if delta > 0 {
            saturation = delta / (1 - abs(2 * lightness - 1))
            if maxV == r {
                hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                hue = 60 * ((b - r) / delta + 2)
            } else {
                hue = 60 * ((r - g) / delta + 4)
            }
            if hue < 0 { hue += 360 }
        }
        return HSL(hue: hue, saturation: saturation, lightness: lightness)
    }

    public static func hslToRGB(_ hsl: HSL) -> RGBA {
        let c = (1 - abs(2 * hsl.lightness - 1)) * hsl.saturation
        let x = c * (1 - abs((hsl.hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = hsl.lightness - c / 2
        let (r, g, b): (Double, Double, Double)
        switch hsl.hue {
        case 0..<60: (r, g, b) = (c, x, 0)
        case 60..<120: (r, g, b) = (x, c, 0)
        case 120..<180: (r, g, b) = (0, c, x)
        case 180..<240: (r, g, b) = (0, x, c)
        case 240..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return RGBA(red: (r + m) * 255, green: (g + m) * 255, blue: (b + m) * 255, alpha: 1)
    }

    // MARK: - 格式化

    public static func css(_ color: RGBA) -> String {
        if color.alpha >= 1 {
            return "rgb(\(Int(color.red.rounded())), \(Int(color.green.rounded())), \(Int(color.blue.rounded())))"
        }
        return "rgba(\(Int(color.red.rounded())), \(Int(color.green.rounded())), \(Int(color.blue.rounded())), \(String(format: "%.2f", color.alpha)))"
    }

    public static func css(_ hsl: HSL) -> String {
        "hsl(\(Int(hsl.hue.rounded())), \(Int((hsl.saturation * 100).rounded()))%, \(Int((hsl.lightness * 100).rounded()))%)"
    }
}

extension Comparable {
    func clamped(_ range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
