import AppKit
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// 文字与快捷工具主界面：左侧工具列表 + 右侧工具面板。
public struct QuickToolsView: View {
    public enum Tool: String, CaseIterable, Identifiable {
        case textClean, findReplace, caseConvert, lineOps, markdown, diff
        case qr, color, calculator, unit, timer, pomodoro

        public var id: String { rawValue }

        var displayName: String {
            switch self {
            case .textClean: return "文本清理"
            case .findReplace: return "查找替换"
            case .caseConvert: return "大小写转换"
            case .lineOps: return "行操作"
            case .markdown: return "Markdown 预览"
            case .diff: return "文本对比"
            case .qr: return "二维码"
            case .color: return "颜色转换"
            case .calculator: return "计算器"
            case .unit: return "单位换算"
            case .timer: return "计时器"
            case .pomodoro: return "番茄钟"
            }
        }

        var icon: String {
            switch self {
            case .textClean: return "sparkles"
            case .findReplace: return "magnifyingglass"
            case .caseConvert: return "textformat"
            case .lineOps: return "list.number"
            case .markdown: return "doc.richtext"
            case .diff: return "arrow.left.arrow.right"
            case .qr: return "qrcode"
            case .color: return "paintpalette"
            case .calculator: return "plus.forwardslash.minus"
            case .unit: return "ruler"
            case .timer: return "timer"
            case .pomodoro: return "stopwatch"
            }
        }
    }

    @State private var selected: Tool = .textClean

    public init() {}

    public var body: some View {
        ToolContainer("文字与快捷工具", subtitle: "Text & Quick Tools") {
            HSplitView {
                List(selection: $selected) {
                    ForEach(Tool.allCases) { tool in
                        Label(tool.displayName, systemImage: tool.icon).tag(tool)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 180, idealWidth: 200)

                Group {
                    switch selected {
                    case .textClean: TextCleanPane()
                    case .findReplace: FindReplacePane()
                    case .caseConvert: CaseConvertPane()
                    case .lineOps: LineOpsPane()
                    case .markdown: MarkdownPane()
                    case .diff: DiffPane()
                    case .qr: QRPane()
                    case .color: ColorPane()
                    case .calculator: CalculatorPane()
                    case .unit: UnitPane()
                    case .timer: TimerPane()
                    case .pomodoro: PomodoroPane()
                    }
                }
                .frame(minWidth: 480)
            }
        }
    }
}

// MARK: - 文本工具（共享输入状态模式：每个面板独立）

private struct ToolShell<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TextCleanPane: View {
    @State private var input = ""
    @State private var fullWidth = true
    @State private var trimTrailing = true
    @State private var collapseBlank = true
    @State private var joinCJK = false
    @State private var output = ""

    var body: some View {
        ToolShell(title: "文本清理") {
            TextEditor(text: $input)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Toggle("全角→半角", isOn: $fullWidth)
                Toggle("去行尾空白", isOn: $trimTrailing)
                Toggle("压缩空行", isOn: $collapseBlank)
                Toggle("修复中文断行", isOn: $joinCJK)
                Button("清理") { run() }
                Button("复制结果") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .disabled(output.isEmpty)
            }
            TextEditor(text: .constant(output))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func run() {
        var options: TextToolkit.CleanOptions = []
        if fullWidth { options.insert(.fullWidthToHalf) }
        if trimTrailing { options.insert(.trimTrailingWhitespace) }
        if collapseBlank { options.insert(.collapseBlankLines) }
        if joinCJK { options.insert(.joinCJKLines) }
        output = TextToolkit.clean(input, options: options)
    }
}

private struct FindReplacePane: View {
    @State private var input = ""
    @State private var find = ""
    @State private var replacement = ""
    @State private var caseSensitive = false
    @State private var wholeWords = false
    @State private var isRegex = false
    @State private var output = ""
    @State private var message = ""

    var body: some View {
        ToolShell(title: "查找替换") {
            TextEditor(text: $input)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 130)
                .scrollContentBackground(.hidden)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                TextField("查找", text: $find).textFieldStyle(.roundedBorder)
                TextField("替换为", text: $replacement).textFieldStyle(.roundedBorder)
            }
            HStack {
                Toggle("区分大小写", isOn: $caseSensitive)
                Toggle("全词匹配", isOn: $wholeWords)
                Toggle("正则", isOn: $isRegex)
                Button("全部替换") { run() }
                Button("复制结果") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .disabled(output.isEmpty)
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(message.contains("错误") ? .red : .secondary)
            }
            TextEditor(text: .constant(output))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 130)
                .scrollContentBackground(.hidden)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func run() {
        do {
            let (result, count) = try TextToolkit.findReplace(
                input, find: find, replacement: replacement,
                options: .init(caseSensitive: caseSensitive, wholeWords: wholeWords, isRegex: isRegex))
            output = result
            message = "替换了 \(count) 处"
        } catch {
            output = ""
            message = "错误：\(String(describing: error))"
        }
    }
}

private struct CaseConvertPane: View {
    @State private var input = ""
    @State private var output = ""

    var body: some View {
        ToolShell(title: "大小写转换") {
            TextEditor(text: $input)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            FlowLayoutCompat(items: TextToolkit.CaseStyle.allCases) { style in
                Button(style.displayName) {
                    output = TextToolkit.convertCase(input, style: style)
                }
            }
            HStack {
                Button("复制结果") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .disabled(output.isEmpty)
                Spacer()
                let stats = TextToolkit.statistics(input)
                Text("\(stats.characters) 字符 · \(stats.words) 词 · \(stats.lines) 行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: .constant(output))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct LineOpsPane: View {
    @State private var input = ""
    @State private var output = ""

    var body: some View {
        ToolShell(title: "行操作") {
            TextEditor(text: $input)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            FlowLayoutCompat(items: TextToolkit.LineOperation.allCases) { operation in
                Button(operation.rawValue) {
                    output = operation.apply(input.components(separatedBy: "\n"))
                        .joined(separator: "\n")
                }
            }
            HStack {
                Button("复制结果") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .disabled(output.isEmpty)
            }
            TextEditor(text: .constant(output))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct MarkdownPane: View {
    @State private var input = "# 标题\n\n这是 **粗体** 与 *斜体* 与 `代码`。\n\n- 项目一\n- 项目二\n\n> 引用内容\n\n```swift\nlet x = 1\n```\n\n[合法链接](https://example.com) 与 [危险链接](javascript:alert(1))\n\n---\n"
    @State private var rendered: NSAttributedString = .init(string: "")

    var body: some View {
        ToolShell(title: "Markdown 预览（安全渲染：无 HTML/脚本解释）") {
            HSplitView {
                TextEditor(text: $input)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 240)
                    .scrollContentBackground(.hidden)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                AttributedText(attributed: rendered)
                    .frame(minWidth: 260)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(minHeight: 380)
            .onAppear { rendered = MarkdownRenderer.render(input) }
            .onChange(of: input) { _, newValue in
                rendered = MarkdownRenderer.render(newValue)
            }
        }
    }
}

private struct DiffPane: View {
    @State private var left = ""
    @State private var right = ""
    @State private var result: TextDiff.Result?
    @State private var errorMessage: String?

    var body: some View {
        ToolShell(title: "文本对比（逐行 LCS）") {
            HStack {
                TextEditor(text: $left)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                TextEditor(text: $right)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(minHeight: 180)
            HStack {
                Button("对比") {
                    do {
                        result = try TextDiff.diff(left: left, right: right)
                        errorMessage = nil
                    } catch {
                        errorMessage = String(describing: error)
                    }
                }
                if let result {
                    Text("+\(result.addedCount) −\(result.removedCount) · 相似度 \(Int(result.similarity * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let result {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(result.changes) { change in
                            HStack(spacing: 6) {
                                Text(marker(change.type))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(markerColor(change.type))
                                    .frame(width: 14)
                                Text(change.text.isEmpty ? " " : change.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .strikethrough(change.type == .removed)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(for: change.type))
                            .padding(.horizontal, 4)
                        }
                    }
                }
                .frame(minHeight: 200)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func marker(_ type: TextDiff.ChangeType) -> String {
        switch type {
        case .same: return " "
        case .added: return "+"
        case .removed: return "−"
        }
    }

    private func markerColor(_ type: TextDiff.ChangeType) -> Color {
        switch type {
        case .same: return .secondary
        case .added: return .green
        case .removed: return .red
        }
    }

    private func background(for type: TextDiff.ChangeType) -> Color {
        switch type {
        case .same: return .clear
        case .added: return .green.opacity(0.10)
        case .removed: return .red.opacity(0.10)
        }
    }
}

private struct QRPane: View {
    @State private var payload = "https://example.com"
    @State private var generatedImage: NSImage?
    @State private var detected: [QRCodeService.Payload] = []
    @State private var message = ""

    var body: some View {
        ToolShell(title: "二维码生成与解析") {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("生成").font(.subheadline.bold())
                    TextField("内容（URL 或文本）", text: $payload)
                        .textFieldStyle(.roundedBorder)
                    Button("生成二维码") { generate() }
                    if let generatedImage {
                        Image(nsImage: generatedImage)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 180, height: 180)
                        Button("复制图片") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([generatedImage])
                        }
                    }
                }
                .frame(maxWidth: 240, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("解析").font(.subheadline.bold())
                    Button("从剪贴板图片解析") { detectFromPasteboard() }
                    Button("从文件解析…") { detectFromFile() }
                    if !detected.isEmpty {
                        ForEach(Array(detected.enumerated()), id: \.offset) { _, item in
                            HStack {
                                Image(systemName: item.isURL ? "link" : "text.quote")
                                Text(item.content).font(.system(.callout, design: .monospaced))
                            }
                        }
                    }
                    if !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func generate() {
        do {
            let cg = try QRCodeService.generate(payload: payload)
            generatedImage = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
            message = ""
        } catch {
            message = "生成失败：\(String(describing: error))"
        }
    }

    private func detectFromPasteboard() {
        guard let image = NSPasteboard.general.data(forType: .png)
            ?? NSPasteboard.general.data(forType: .tiff) else {
            message = "剪贴板中没有图片"
            return
        }
        detect(data: image)
    }

    private func detectFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            Task { @MainActor in
                detect(data: data)
            }
        }
    }

    private func detect(data: Data) {
        guard let cg = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            message = "图片解码失败"
            return
        }
        do {
            detected = try QRCodeService.detect(in: cg)
            message = detected.isEmpty ? "未识别到二维码" : "识别到 \(detected.count) 个码"
        } catch {
            message = "解析失败：\(String(describing: error))"
        }
    }
}

private struct ColorPane: View {
    @State private var hexInput = "#4A90D9"
    @State private var color: ColorToolkit.RGBA?
    @State private var message = ""

    var body: some View {
        ToolShell(title: "颜色转换") {
            HStack {
                TextField("#RRGGBB 或 #RRGGBBAA", text: $hexInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("解析") { parse() }
                if let color {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: NSColor(calibratedRed: color.red / 255, green: color.green / 255, blue: color.blue / 255, alpha: color.alpha)))
                        .frame(width: 32, height: 32)
                }
            }
            if let color {
                let hsv = ColorToolkit.rgbToHSV(color)
                let hsl = ColorToolkit.rgbToHSL(color)
                VStack(alignment: .leading, spacing: 6) {
                    format("HEX", ColorToolkit.toHex(color, includeAlpha: true))
                    format("RGB", "\(Int(color.red)), \(Int(color.green)), \(Int(color.blue))")
                    format("CSS", ColorToolkit.css(color))
                    format("HSV", String(format: "%.0f°, %.0f%%, %.0f%%", hsv.hue, hsv.saturation * 100, hsv.value * 100))
                    format("HSL", ColorToolkit.css(hsl))
                }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func parse() {
        do {
            color = try ColorToolkit.parseHex(hexInput)
            message = ""
        } catch {
            color = nil
            message = String(describing: error)
        }
    }

    private func format(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}

private struct CalculatorPane: View {
    @State private var expression = ""
    @State private var result = ""
    @State private var useDecimal = false
    @State private var isError = false

    private let presets = ["(1+2)*3", "2^10", "sqrt(144)", "log10(1000)", "sin(pi/2)", "1e3/7", "0.1+0.2"]

    var body: some View {
        ToolShell(title: "计算器（表达式求值）") {
            TextField("输入表达式，如 (1+2)*3 - sqrt(16)", text: $expression)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
                .onSubmit { calculate() }
            HStack {
                Toggle("Decimal 精确模式（金额）", isOn: $useDecimal)
                Button("计算") { calculate() }
                if !result.isEmpty {
                    Text(isError ? result : "= \(result)")
                        .font(.title3.monospaced())
                        .foregroundStyle(isError ? .red : .primary)
                        .textSelection(.enabled)
                }
            }
            FlowLayoutCompat(items: presets) { preset in
                Button(preset) {
                    expression = preset
                    calculate()
                }
                .buttonStyle(.link)
            }
        }
    }

    private func calculate() {
        do {
            if useDecimal {
                let value = try Calculator.evaluateDecimal(expression)
                result = "\(value)"
                isError = false
            } else {
                let value = try Calculator.evaluate(expression)
                result = formatNumber(value)
                isError = false
            }
        } catch {
            result = String(describing: error)
            isError = true
        }
    }

    private func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.10g", value)
    }
}

private struct UnitPane: View {
    @State private var category: UnitConverter.Category = .length
    @State private var fromUnit = "m"
    @State private var toUnit = "ft"
    @State private var valueText = "1"
    @State private var resultText = ""
    @State private var isError = false

    var body: some View {
        ToolShell(title: "单位换算") {
            Picker("类别", selection: Binding(
                get: { category },
                set: { newCategory in
                    category = newCategory
                    let units = UnitConverter.units(in: newCategory)
                    fromUnit = units.first?.symbol ?? ""
                    toUnit = units.count > 1 ? units[1].symbol : units.first?.symbol ?? ""
                    resultText = ""
                })) {
                ForEach(UnitConverter.Category.allCases, id: \.self) { c in
                    Text(c.displayName).tag(c)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                TextField("数值", text: $valueText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Picker("", selection: $fromUnit) {
                    ForEach(UnitConverter.units(in: category), id: \.symbol) { unit in
                        Text("\(unit.displayName) (\(unit.symbol))").tag(unit.symbol)
                    }
                }
                Image(systemName: "arrow.right")
                Picker("", selection: $toUnit) {
                    ForEach(UnitConverter.units(in: category), id: \.symbol) { unit in
                        Text("\(unit.displayName) (\(unit.symbol))").tag(unit.symbol)
                    }
                }
                Button("换算") { convert() }
            }
            if !resultText.isEmpty {
                Text(resultText)
                    .font(.title3.monospaced())
                    .foregroundStyle(isError ? .red : .primary)
                    .textSelection(.enabled)
            }
        }
    }

    private func convert() {
        guard let value = Double(valueText) else {
            resultText = "数值无效"
            isError = true
            return
        }
        do {
            let result = try UnitConverter.convert(value: value, from: fromUnit, to: toUnit)
            resultText = String(format: "%.6g", result)
            isError = false
        } catch {
            resultText = String(describing: error)
            isError = true
        }
    }
}

private struct TimerPane: View {
    @State private var state = CountdownState(durationSeconds: 300)
    @State private var durationMinutes = 5

    var body: some View {
        ToolShell(title: "计时器") {
            Text(timeText)
                .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
            HStack {
                Stepper("时长：\(durationMinutes) 分钟", value: $durationMinutes, in: 1...180)
                    .disabled(state.phase == .running)
                Button(state.phase == .paused ? "继续" : "开始") {
                    state.durationSeconds = durationMinutes * 60
                    state.start(at: Date())
                }
                .disabled(state.phase == .running || state.phase == .finished)
                Button("暂停") { state.pause() }
                    .disabled(state.phase != .running)
                Button("复位") {
                    state = CountdownState(durationSeconds: durationMinutes * 60)
                }
            }
            if state.phase == .finished {
                Label("时间到", systemImage: "bell.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
            }
        }
        // phase 变化驱动循环启停；视图消失自动取消
        .task(id: state.phase) {
            guard state.phase == .running else { return }
            while state.phase == .running {
                try? await Task.sleep(for: .milliseconds(250))
                if state.tick(at: Date()) {
                    NSSound.beep()
                    break
                }
            }
        }
    }

    private var timeText: String {
        let total = state.remainingSeconds
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct PomodoroPane: View {
    @State private var state = PomodoroState(workMinutes: 25, breakMinutes: 5, targetSessions: 0)
    @State private var workMinutes = 25
    @State private var breakMinutes = 5
    @State private var targetSessions = 4
    @State private var lastEvent = ""

    var body: some View {
        ToolShell(title: "番茄钟") {
            Text("\(state.phase == .breakTime ? "休息" : "专注") \(timeText)")
                .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(state.phase == .breakTime ? .green : .primary)
            HStack {
                Stepper("专注 \(workMinutes) 分钟", value: $workMinutes, in: 5...90, step: 5)
                    .disabled(state.phase != .idle)
                Stepper("休息 \(breakMinutes) 分钟", value: $breakMinutes, in: 1...30)
                    .disabled(state.phase != .idle)
                Stepper("目标 \(targetSessions) 轮", value: $targetSessions, in: 1...12)
                    .disabled(state.phase != .idle)
            }
            HStack {
                Button(state.phase == .breakTime ? "跳过休息" : "开始") { advanceOrStart() }
                Button("暂停") { state.pause(at: Date()) }
                    .disabled(state.phase == .idle || state.phase == .finished)
                Button("复位") {
                    state = PomodoroState(
                        workMinutes: workMinutes, breakMinutes: breakMinutes,
                        targetSessions: targetSessions)
                    lastEvent = ""
                }
                Spacer()
                Text("已完成 \(state.completedWorkSessions) 轮")
                    .foregroundStyle(.secondary)
            }
            if !lastEvent.isEmpty {
                Label(lastEvent, systemImage: "bell.fill").foregroundStyle(.orange)
            }
        }
        // phase 变化驱动循环启停；视图消失自动取消
        .task(id: state.phase) {
            while state.phase == .work || state.phase == .breakTime {
                try? await Task.sleep(for: .milliseconds(250))
                switch state.tick(at: Date()) {
                case .workFinished:
                    lastEvent = "专注完成，休息一下"
                    NSSound.beep()
                case .breakFinished:
                    lastEvent = "休息结束，开始新一轮专注"
                    NSSound.beep()
                case .allFinished:
                    lastEvent = "全部目标轮次完成！"
                    NSSound.beep()
                case .none:
                    break
                }
            }
        }
    }

    private var timeText: String {
        let total = state.remainingSeconds
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func advanceOrStart() {
        if state.phase == .idle {
            state = PomodoroState(
                workMinutes: workMinutes, breakMinutes: breakMinutes,
                targetSessions: targetSessions)
            state.start(at: Date())
        } else if state.phase == .breakTime {
            state.phase = .work
            state.countdown = CountdownState(durationSeconds: state.workDurationSeconds)
            state.countdown.start(at: Date())
        }
    }
}

// MARK: - 通用组件

/// 简单流式布局（按钮换行）。
struct FlowLayoutCompat<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}

/// NSAttributedString 展示。
struct AttributedText: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.drawsBackground = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        view.textStorage?.setAttributedString(attributed)
    }
}
