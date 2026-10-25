import Foundation
import DeskvanicCore

/// 单位换算：长度/质量/温度/数据/时间/角度/速度/面积/体积/功率。
public enum UnitConverter {

    public struct Unit: Hashable, Sendable {
        public let symbol: String
        public let displayName: String
        /// 相对基准单位的倍率（线性单位）。
        public let factor: Double
        /// 仿射单位（温度）时使用偏移；线性单位为 nil。
        public let affineOffset: Double?
        /// 所属类别。
        public let category: Category

        init(category: Category, symbol: String, displayName: String,
             factor: Double, affineOffset: Double? = nil) {
            self.category = category
            self.symbol = symbol
            self.displayName = displayName
            self.factor = factor
            self.affineOffset = affineOffset
        }
    }

    public enum Category: String, CaseIterable, Sendable {
        case length, mass, temperature, data, time, angle, speed, area, volume, power

        public var displayName: String {
            switch self {
            case .length: return "长度"
            case .mass: return "质量"
            case .temperature: return "温度"
            case .data: return "数据存储"
            case .time: return "时间"
            case .angle: return "角度"
            case .speed: return "速度"
            case .area: return "面积"
            case .volume: return "体积"
            case .power: return "功率"
            }
        }
    }

    // MARK: - 单位表

    public static let allUnits: [Unit] = [
        // 长度（基准：米）
        Unit(category: .length, symbol: "mm", displayName: "毫米", factor: 0.001),
        Unit(category: .length, symbol: "cm", displayName: "厘米", factor: 0.01),
        Unit(category: .length, symbol: "m", displayName: "米", factor: 1),
        Unit(category: .length, symbol: "km", displayName: "千米", factor: 1000),
        Unit(category: .length, symbol: "in", displayName: "英寸", factor: 0.0254),
        Unit(category: .length, symbol: "ft", displayName: "英尺", factor: 0.3048),
        Unit(category: .length, symbol: "yd", displayName: "码", factor: 0.9144),
        Unit(category: .length, symbol: "mi", displayName: "英里", factor: 1609.344),
        // 质量（基准：千克）
        Unit(category: .mass, symbol: "mg", displayName: "毫克", factor: 1e-6),
        Unit(category: .mass, symbol: "g", displayName: "克", factor: 0.001),
        Unit(category: .mass, symbol: "kg", displayName: "千克", factor: 1),
        Unit(category: .mass, symbol: "t", displayName: "吨", factor: 1000),
        Unit(category: .mass, symbol: "oz", displayName: "盎司", factor: 0.028349523125),
        Unit(category: .mass, symbol: "lb", displayName: "磅", factor: 0.45359237),
        // 温度（仿射）
        Unit(category: .temperature, symbol: "°C", displayName: "摄氏度", factor: 1, affineOffset: 0),
        Unit(category: .temperature, symbol: "°F", displayName: "华氏度", factor: 5.0 / 9.0, affineOffset: -32),
        Unit(category: .temperature, symbol: "K", displayName: "开尔文", factor: 1, affineOffset: -273.15),
        // 数据（二进制基准：字节；区分 1000/1024 两套）
        Unit(category: .data, symbol: "B", displayName: "字节", factor: 1),
        Unit(category: .data, symbol: "KB", displayName: "千字节(1000)", factor: 1000),
        Unit(category: .data, symbol: "KiB", displayName: "千字节(1024)", factor: 1024),
        Unit(category: .data, symbol: "MB", displayName: "兆字节(1000)", factor: 1_000_000),
        Unit(category: .data, symbol: "MiB", displayName: "兆字节(1024)", factor: 1_048_576),
        Unit(category: .data, symbol: "GB", displayName: "吉字节(1000)", factor: 1e9),
        Unit(category: .data, symbol: "GiB", displayName: "吉字节(1024)", factor: 1_073_741_824),
        Unit(category: .data, symbol: "TB", displayName: "太字节(1000)", factor: 1e12),
        Unit(category: .data, symbol: "TiB", displayName: "太字节(1024)", factor: 1_099_511_627_776),
        // 时间（基准：秒）
        Unit(category: .time, symbol: "ms", displayName: "毫秒", factor: 0.001),
        Unit(category: .time, symbol: "s", displayName: "秒", factor: 1),
        Unit(category: .time, symbol: "min", displayName: "分", factor: 60),
        Unit(category: .time, symbol: "h", displayName: "小时", factor: 3600),
        Unit(category: .time, symbol: "day", displayName: "天", factor: 86_400),
        // 角度（基准：度）
        Unit(category: .angle, symbol: "deg", displayName: "度", factor: 1),
        Unit(category: .angle, symbol: "rad", displayName: "弧度", factor: 180 / Double.pi),
        // 速度（基准：米/秒）
        Unit(category: .speed, symbol: "m/s", displayName: "米每秒", factor: 1),
        Unit(category: .speed, symbol: "km/h", displayName: "千米每小时", factor: 1.0 / 3.6),
        Unit(category: .speed, symbol: "mph", displayName: "英里每小时", factor: 0.44704),
        // 面积（基准：平方米）
        Unit(category: .area, symbol: "m²", displayName: "平方米", factor: 1),
        Unit(category: .area, symbol: "km²", displayName: "平方千米", factor: 1e6),
        Unit(category: .area, symbol: "ft²", displayName: "平方英尺", factor: 0.09290304),
        Unit(category: .area, symbol: "亩", displayName: "亩", factor: 666.6667),
        // 体积（基准：升）
        Unit(category: .volume, symbol: "mL", displayName: "毫升", factor: 0.001),
        Unit(category: .volume, symbol: "L", displayName: "升", factor: 1),
        Unit(category: .volume, symbol: "m³", displayName: "立方米", factor: 1000),
        Unit(category: .volume, symbol: "gal(US)", displayName: "美制加仑", factor: 3.785411784),
        // 功率（基准：瓦）
        Unit(category: .power, symbol: "W", displayName: "瓦", factor: 1),
        Unit(category: .power, symbol: "kW", displayName: "千瓦", factor: 1000),
        Unit(category: .power, symbol: "hp", displayName: "马力", factor: 745.699872),
    ]

    public static func units(in category: Category) -> [Unit] {
        allUnits.filter { $0.category == category }
    }

    public static func unit(symbol: String) -> Unit? {
        allUnits.first { $0.symbol == symbol }
    }

    // MARK: - 换算

    /// 通用换算：单位类别不匹配或未知单位报错。仿射单位（温度）正确处理。
    public static func convert(value: Double, from: String, to: String) throws -> Double {
        guard let source = unit(symbol: from) else {
            throw DeskvanicError(.invalidInput, "未知单位：\(from)")
        }
        guard let target = unit(symbol: to) else {
            throw DeskvanicError(.invalidInput, "未知单位：\(to)")
        }
        guard source.category == target.category else {
            throw DeskvanicError(.invalidInput, "单位类别不匹配：\(source.displayName) 与 \(target.displayName)")
        }
        return convertValue(value, from: source, to: target)
    }

    static func convertValue(_ value: Double, from: Unit, to: Unit) -> Double {
        // 基准值：线性直接乘；仿射先转到基准（线性部分）再处理偏移
        func toBase(_ v: Double, _ unit: Unit) -> Double {
            let base = v * unit.factor
            if let offset = unit.affineOffset {
                return (v + offset) * unit.factor
            }
            return base
        }
        func fromBase(_ v: Double, _ unit: Unit) -> Double {
            let scaled = v / unit.factor
            if let offset = unit.affineOffset {
                return scaled - offset
            }
            return scaled
        }
        return fromBase(toBase(value, from), to)
    }
}
