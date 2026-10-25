import AppKit
import CoreGraphics
import CoreImage
import Foundation
import Testing
import DeskvanicCore
@testable import DeskvanicQuickTools

@Suite("TextToolkit")
struct TextToolkitTests {
    @Test func cleanOptions() {
        let text = "ＡＢＣ１２３  \n中文第一行\n继续句子\n\n\n\n最后"
        let cleaned = TextToolkit.clean(text, options: [
            .fullWidthToHalf, .trimTrailingWhitespace, .collapseBlankLines, .joinCJKLines,
        ])
        #expect(cleaned.contains("ABC123"))
        // 中文断行合并
        #expect(cleaned.contains("中文第一行继续句子"))
        // 空行压缩：最多保留一个空行
        #expect(!cleaned.contains("\n\n\n"))
    }

    @Test func joinCJKPreservesStructure() {
        let lines = ["标题行", "- 列表项一", "中文句子被", "打断", "", "然后新段落"]
        let joined = TextToolkit.joinCJKBrokenLines(lines)
        #expect(joined[0] == "标题行")
        #expect(joined.contains("中文句子被打断"))
        #expect(joined.contains("然后新段落"))
        // 列表项不与相邻内容合并
        #expect(joined.contains("- 列表项一"))
    }

    @Test func findReplaceLiteralAndCount() throws {
        let (result, count) = try TextToolkit.findReplace(
            "苹果 apple Apple apple pie", find: "apple", replacement: "香蕉",
            options: .init(caseSensitive: false))
        #expect(count == 3)
        #expect(result == "苹果 香蕉 香蕉 香蕉 pie")

        let (caseResult, caseCount) = try TextToolkit.findReplace(
            "a A a", find: "a", replacement: "x", options: .init(caseSensitive: true))
        #expect(caseCount == 2)
        #expect(caseResult == "x A x")
    }

    @Test func findReplaceWholeWordAndRegex() throws {
        let (whole, wholeCount) = try TextToolkit.findReplace(
            "cat category cat", find: "cat", replacement: "dog",
            options: .init(wholeWords: true))
        #expect(wholeCount == 2)
        #expect(whole == "dog category dog")

        let (regexResult, regexCount) = try TextToolkit.findReplace(
            "a1b2c3", find: "[0-9]", replacement: "#",
            options: .init(isRegex: true))
        #expect(regexCount == 3)
        #expect(regexResult == "a#b#c#")
    }

    @Test func invalidRegexThrowsNotCrashes() {
        #expect(throws: DeskvanicError.self) {
            _ = try TextToolkit.findReplace("abc", find: "[unclosed", replacement: "x",
                                            options: .init(isRegex: true))
        }
    }

    @Test func replacementTemplateNotInterpretedInLiteralMode() throws {
        // 字面量模式：$0 等模板占位符不应被解释
        let (result, _) = try TextToolkit.findReplace(
            "abc", find: "b", replacement: "$0$1", options: .init(isRegex: false))
        #expect(result == "a$0$1c")
    }

    @Test func caseStyles() {
        #expect(TextToolkit.convertCase("hello world", style: .upper) == "HELLO WORLD")
        #expect(TextToolkit.convertCase("HELLO WORLD", style: .lower) == "hello world")
        #expect(TextToolkit.convertCase("user_name field", style: .camel) == "userNameField")
        #expect(TextToolkit.convertCase("UserProfileView", style: .snake) == "user_profile_view")
        #expect(TextToolkit.convertCase("Some Term", style: .kebab) == "some-term")
        let sentence = TextToolkit.convertCase("hello. world", style: .sentence)
        #expect(sentence.hasPrefix("Hello"))
    }

    @Test func naturalSort() {
        let lines = ["a10", "a2", "a1"]
        let sorted = TextToolkit.LineOperation.sortNatural.apply(lines)
        #expect(sorted == ["a1", "a2", "a10"])
        #expect(TextToolkit.compareNatural("a2", "a10") == .orderedAscending)
        #expect(TextToolkit.compareNatural("a10", "a2") == .orderedDescending)
        #expect(TextToolkit.compareNatural("same", "same") == .orderedSame)
    }

    @Test func deduplicateKeepsOrder() {
        let result = TextToolkit.LineOperation.deduplicate.apply(["b", "a", "b", "c", "a"])
        #expect(result == ["b", "a", "c"])
    }

    @Test func statisticsMixedCJKLatin() {
        let stats = TextToolkit.statistics("hello 世界 世界 abc")
        #expect(stats.characters == 15)
        #expect(stats.cjkCharacters == 4)
        #expect(stats.words == 6)  // hello + 世界×2 + abc = 1+2+1+2
        #expect(stats.lines == 1)
        #expect(stats.bytes > stats.characters)  // UTF-8 CJK 多字节
    }

    @Test func largeInputPerformanceAcceptable() {
        let big = String(repeating: "行内容测试 line content\n", count: 40_000)
        let start = Date()
        _ = TextToolkit.statistics(big)
        _ = TextToolkit.clean(big, options: [.trimTrailingWhitespace])
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5.0, "1MB 级文本统计与清理应在 5 秒内，实际 \(elapsed)s")
    }
}

@Suite("Calculator")
struct CalculatorTests {
    @Test func basicArithmeticAndPrecedence() throws {
        #expect(try Calculator.evaluate("1+2*3") == 7)
        #expect(try Calculator.evaluate("(1+2)*3") == 9)
        #expect(try Calculator.evaluate("10/4") == 2.5)
        #expect(try Calculator.evaluate("7%3") == 1)
        #expect(try Calculator.evaluate("2^10") == 1024)
        #expect(try Calculator.evaluate("2^3^2") == 512)  // 右结合
        #expect(try Calculator.evaluate("-5+3") == -2)
        #expect(try Calculator.evaluate("--5") == 5)
        #expect(try Calculator.evaluate("10-2-3") == 5)  // 左结合
    }

    @Test func constantsAndFunctions() throws {
        #expect(try Calculator.evaluate("pi") == Double.pi)
        #expect(try Calculator.evaluate("e") == M_E)
        #expect(try Calculator.evaluate("sqrt(144)") == 12)
        #expect(abs(try Calculator.evaluate("sin(pi/2)") - 1) < 1e-12)
        #expect(try Calculator.evaluate("log10(1000)") == 3)
        #expect(try Calculator.evaluate("log2(8)") == 3)
        #expect(try Calculator.evaluate("log(e)") == 1)
        #expect(try Calculator.evaluate("abs(-3.5)") == 3.5)
        #expect(try Calculator.evaluate("exp(0)") == 1)
        #expect(try Calculator.evaluate("1e3") == 1000)
        #expect(try Calculator.evaluate("2.5e-2") == 0.025)
    }

    @Test func errorCases() {
        #expect(throws: DeskvanicError.self) { _ = try Calculator.evaluate("1/0") }
        #expect(throws: DeskvanicError.self) { _ = try Calculator.evaluate("1+") }
        #expect(throws: DeskvanicError.self) { _ = try Calculator.evaluate("(1+2") }
        #expect(throws: DeskvanicError.self) { _ = try Calculator.evaluate("sqrt(-1)") }
        #expect(throws: DeskvanicError.self) { _ = try Calculator.evaluate("unknown(1)") }
        #expect(throws: DeskvanicError.self) { _ = try Calculator.evaluate("1 2") }
        #expect(throws: DeskvanicError.self) { _ = try Calculator.evaluate("") }
        #expect(throws: DeskvanicError.self) { _ = try Calculator.evaluate("1e") }
    }

    @Test func decimalPrecision() throws {
        // 浮点模式下 0.1+0.2 != 0.3
        let double = try Calculator.evaluate("0.1+0.2")
        #expect(double != 0.3)
        // Decimal 模式精确
        let decimal = try Calculator.evaluateDecimal("0.1+0.2")
        #expect(decimal == Decimal(string: "0.3"))
    }

    @Test func nestedParensAndComplex() throws {
        #expect(try Calculator.evaluate("((2+3)*(4-1))^2") == 225)
        #expect(abs(try Calculator.evaluate("sqrt(3^2+4^2)") - 5) < 1e-12)
    }
}

@Suite("UnitConverter")
struct UnitConverterTests {
    @Test func lengthKnownValues() throws {
        #expect(try UnitConverter.convert(value: 1, from: "in", to: "mm") == 25.4)
        #expect(abs(try UnitConverter.convert(value: 1, from: "mi", to: "km") - 1.609344) < 1e-9)
        #expect(try UnitConverter.convert(value: 1, from: "km", to: "m") == 1000)
    }

    @Test func temperatureAffine() throws {
        #expect(try UnitConverter.convert(value: 0, from: "°C", to: "°F") == 32)
        #expect(abs(try UnitConverter.convert(value: 0, from: "°C", to: "K") - 273.15) < 1e-9)
        #expect(try UnitConverter.convert(value: 100, from: "°C", to: "°F") == 212)
        #expect(abs(try UnitConverter.convert(value: 98.6, from: "°F", to: "°C") - 37) < 1e-9)
    }

    @Test func dataBinaryVsDecimal() throws {
        #expect(try UnitConverter.convert(value: 1, from: "MiB", to: "B") == 1_048_576)
        #expect(try UnitConverter.convert(value: 1, from: "MB", to: "B") == 1_000_000)
        #expect(abs(try UnitConverter.convert(value: 1, from: "GiB", to: "MiB") - 1024) < 1e-9)
    }

    @Test func speedAndMass() throws {
        #expect(try UnitConverter.convert(value: 3.6, from: "km/h", to: "m/s") == 1)
        #expect(abs(try UnitConverter.convert(value: 1, from: "lb", to: "kg") - 0.45359237) < 1e-9)
        #expect(try UnitConverter.convert(value: 1, from: "t", to: "kg") == 1000)
    }

    @Test func categoryMismatchRejected() {
        #expect(throws: DeskvanicError.self) {
            _ = try UnitConverter.convert(value: 1, from: "m", to: "kg")
        }
        #expect(throws: DeskvanicError.self) {
            _ = try UnitConverter.convert(value: 1, from: "unknown", to: "m")
        }
    }
}

@Suite("ColorToolkit")
struct ColorToolkitTests {
    @Test func hexParsingVariants() throws {
        let short = try ColorToolkit.parseHex("#F00")
        #expect(short.red == 255 && short.green == 0 && short.blue == 0)
        let full = try ColorToolkit.parseHex("#4A90D9")
        #expect(full.red == 74 && full.green == 144 && full.blue == 217)
        let alpha = try ColorToolkit.parseHex("#FF000080")
        #expect(alpha.red == 255 && alpha.alpha < 1)
    }

    @Test func invalidHexRejected() {
        #expect(throws: DeskvanicError.self) { _ = try ColorToolkit.parseHex("#GGGGGG") }
        #expect(throws: DeskvanicError.self) { _ = try ColorToolkit.parseHex("#12345") }
        #expect(throws: DeskvanicError.self) { _ = try ColorToolkit.parseHex("") }
    }

    @Test func hexRoundtrip() throws {
        let original = try ColorToolkit.parseHex("#12ABEF")
        let hex = ColorToolkit.toHex(original)
        let reparsed = try ColorToolkit.parseHex(hex)
        #expect(reparsed.red == original.red && reparsed.green == original.green && reparsed.blue == original.blue)
    }

    @Test func hsvHslConversions() {
        let red = ColorToolkit.RGBA(red: 255, green: 0, blue: 0)
        let hsv = ColorToolkit.rgbToHSV(red)
        #expect(hsv.hue == 0 && hsv.saturation == 1 && hsv.value == 1)
        let back = ColorToolkit.hsvToRGB(hsv)
        #expect(abs(back.red - 255) < 1e-6 && back.green < 1e-6 && back.blue < 1e-6)

        let hsl = ColorToolkit.rgbToHSL(red)
        #expect(hsl.hue == 0 && hsl.saturation == 1 && hsl.lightness == 0.5)
        let backHSL = ColorToolkit.hslToRGB(hsl)
        #expect(abs(backHSL.red - 255) < 1e-6)
    }

    @Test func cssFormatting() {
        let css = ColorToolkit.css(ColorToolkit.RGBA(red: 74, green: 144, blue: 217))
        #expect(css == "rgb(74, 144, 217)")
    }
}

@Suite("QRCodeService")
struct QRCodeServiceTests {
    @Test func generateThenDetectRoundtrip() throws {
        let payload = "https://deskvanic.example/中文?query=1"
        let image = try QRCodeService.generate(payload: payload, scale: 6)
        let detected = try QRCodeService.detect(in: image)
        #expect(detected.count == 1)
        #expect(detected.first?.content == payload)
        #expect(detected.first?.isURL == true)
    }

    @Test func generateRejectsInvalid() {
        #expect(throws: DeskvanicError.self) { _ = try QRCodeService.generate(payload: "") }
        #expect(throws: DeskvanicError.self) { _ = try QRCodeService.generate(payload: "x", scale: 0) }
        #expect(throws: DeskvanicError.self) { _ = try QRCodeService.generate(payload: "x", scale: 64) }
    }

    @Test func dangerousSchemeDowngrades() {
        let payload = QRCodeService.makePayload("javascript:alert(1)")
        #expect(payload.isURL == false)
        let data = QRCodeService.makePayload("data:text/html;base64,AAAA")
        #expect(data.isURL == false)
        let plain = QRCodeService.makePayload("just text")
        #expect(plain.isURL == false)
    }

    @Test func emptyImageDetectsNothing() throws {
        let context = CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = context.makeImage()!
        let detected = try QRCodeService.detect(in: image)
        #expect(detected.isEmpty)
    }
}

@Suite("TextDiff")
struct TextDiffTests {
    @Test func basicDiff() throws {
        let left = "line1\nline2\nline3"
        let right = "line1\nline2-modified\nline3\nline4"
        let result = try TextDiff.diff(left: left, right: right)
        #expect(result.removedCount >= 1)
        #expect(result.addedCount >= 2)
        #expect(result.sameCount >= 2)
        #expect(result.similarity > 0)
    }

    @Test func identicalTexts() throws {
        let result = try TextDiff.diff(left: "a\nb", right: "a\nb")
        #expect(result.addedCount == 0 && result.removedCount == 0)
        #expect(result.similarity == 1)
    }

    @Test func emptyVsNonEmpty() throws {
        let result = try TextDiff.diff(left: "", right: "x\ny")
        #expect(result.addedCount == 2)
    }

    @Test func oversizeInputRejected() {
        let big = String(repeating: "line\n", count: 300_000)
        #expect(throws: DeskvanicError.self) { _ = try TextDiff.diff(left: big, right: big) }
    }
}

@Suite("MarkdownRenderer")
struct MarkdownRendererTests {
    @Test func parseStructure() {
        let markdown = "# 标题\n\n段落一\n\n- 项目\n\n> 引用\n\n```swift\ncode\n```\n\n---\n"
        let elements = MarkdownRenderer.parse(markdown)
        #expect(elements.contains { $0 == .heading(level: 1, text: "标题") })
        #expect(elements.contains { if case .codeBlock(let lang, let code) = $0 { return lang == "swift" && code == "code" } else { return false } })
        #expect(elements.contains(.divider))
        #expect(elements.contains { if case .list(let items, false) = $0 { return items.first?.text == "项目" } else { return false } })
    }

    @Test func orderedListParsing() {
        let elements = MarkdownRenderer.parse("1. 第一\n2. 第二\n")
        #expect(elements.contains { if case .list(let items, true) = $0 { return items.count == 2 } else { return false } })
    }

    @Test func safeLinksKept() {
        let rendered = MarkdownRenderer.render("[站点](https://example.com)")
        #expect(rendered.length > 0)
        let link = rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL
        #expect(link?.absoluteString == "https://example.com")
    }

    @Test func dangerousSchemeDropped() {
        // javascript: 链接必须降级为纯文本（无 link 属性）
        let rendered = MarkdownRenderer.render("[点击](javascript:alert(1))")
        for i in 0..<rendered.length {
            #expect(rendered.attribute(.link, at: i, effectiveRange: nil) == nil,
                    "位置 \(i) 不应有可点击链接")
        }
    }

    @Test func noHTMLExecution() {
        // HTML/脚本标签按字面文本渲染
        let rendered = MarkdownRenderer.render("<script>alert(1)</script>")
        let plain = String(rendered.string)
        #expect(plain.contains("<script>"))  // 原样文本，不会成为标签
    }

    @Test func boldItalicCode() {
        let rendered = MarkdownRenderer.render("**粗** *斜* `码`")
        let bold = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let traits = bold.map { NSFontManager.shared.traits(of: $0) } ?? []
        #expect(traits.contains(.boldFontMask))
    }
}

@Suite("TimerModels")
struct TimerModelsTests {
    @Test func countdownLifecycle() {
        var state = CountdownState(durationSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        state.start(at: t0)
        #expect(state.phase == .running)
        #expect(state.tick(at: t0.addingTimeInterval(4)) == false)
        #expect(state.remainingSeconds == 6)
        state.pause()
        #expect(state.phase == .paused)
        // 暂停期间 tick 不推进
        #expect(state.tick(at: t0.addingTimeInterval(10)) == false)
        #expect(state.remainingSeconds == 6)
        state.start(at: t0.addingTimeInterval(20))
        #expect(state.tick(at: t0.addingTimeInterval(30)) == true)  // 到达结束
        #expect(state.phase == .finished)
        state.reset()
        #expect(state.remainingSeconds == 10 && state.phase == .idle)
    }

    @Test func pomodoroFullCycle() {
        var state = PomodoroState(workMinutes: 25, breakMinutes: 5, targetSessions: 2)
        let t0 = Date(timeIntervalSince1970: 2000)
        state.start(at: t0)
        #expect(state.phase == .work)

        // 25 分钟工作
        #expect(state.tick(at: t0.addingTimeInterval(25 * 60)) == .workFinished)
        #expect(state.phase == .breakTime)
        #expect(state.completedWorkSessions == 1)

        // 5 分钟休息
        #expect(state.tick(at: t0.addingTimeInterval(30 * 60)) == .breakFinished)
        #expect(state.phase == .work)

        // 第二轮工作
        #expect(state.tick(at: t0.addingTimeInterval(55 * 60)) == .allFinished)
        #expect(state.phase == .finished)
        #expect(state.completedWorkSessions == 2)
    }

    @Test func pomodoroPauseResume() {
        var state = PomodoroState(workMinutes: 25, breakMinutes: 5, targetSessions: 2)
        let t0 = Date(timeIntervalSince1970: 3000)
        state.start(at: t0)
        state.pause(at: t0.addingTimeInterval(5 * 60))
        // 暂停期间的 tick 不产生推进
        #expect(state.tick(at: t0.addingTimeInterval(30 * 60)) == .none)
        state.resume(at: t0.addingTimeInterval(10 * 60))
        #expect(state.tick(at: t0.addingTimeInterval(35 * 60)) == .workFinished)
    }
}
