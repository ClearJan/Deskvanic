import AppKit
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// FlowEngine 服务装配点。
@MainActor
public enum FlowServices {
    public static var store = FlowStore(database: Database(url: AppEnvironment.databaseURL))
    public static let registry = ActionRegistry()
    public static let engine = FlowEngine(registry: registry)
    /// 文件夹触发监视器（按工作流 ID 管理）。
    public static var watchers: [String: FolderWatcher] = [:]

    public static func inject(store newStore: FlowStore) {
        store = newStore
    }
}

/// FlowEngine 主界面。
public struct FlowView: View {
    @State private var workflows: [FlowWorkflow] = []
    @State private var selected: FlowWorkflow?
    @State private var runRecord: FlowRunRecord?
    @State private var running = false
    @State private var statusMessage: String?
    @State private var descriptors: [ActionDescriptor] = []
    @State private var validationErrors: [FlowValidationError] = []

    public init() {}

    public var body: some View {
        ToolContainer("自动化工作流", subtitle: "Flow Engine · 类型检查 · 真实动作 · 可取消") {
            HSplitView {
                workflowList.frame(minWidth: 240, idealWidth: 280)
                editorPane.frame(minWidth: 560)
            }
        }
        .task { await reload() }
    }

    private var workflowList: some View {
        List(workflows, selection: Binding(
            get: { selected?.id },
            set: { id in
                selected = workflows.first { $0.id == id }
                validate()
            })) { workflow in
            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name).lineLimit(1)
                Text("\(workflow.nodes.count) 节点 · \(triggerLabel(workflow.trigger))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contextMenu {
                Button("导出…") { export(workflow) }
                Divider()
                Button("删除", role: .destructive) {
                    Task {
                        try? await FlowServices.store.delete(id: workflow.id)
                        await reload()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if workflows.isEmpty {
                ContentUnavailableView("暂无工作流", systemImage: "flowchart",
                                       description: Text("用右上角「新建」创建，或导入 JSON。"))
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Button("新建") { createNew() }
                Button("导入…") { importJSON() }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let workflow = Binding($selected) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField("名称", text: workflow.name)
                            .textFieldStyle(.roundedBorder)
                        Button("保存") { Task { await save() } }
                        Button("运行") { Task { await run(dryRun: false) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(running)
                        Button("模拟运行") { Task { await run(dryRun: true) } }
                            .disabled(running)
                        if running {
                            Button("取消", role: .destructive) {
                                Task {
                                    if let record = runRecord {
                                        await FlowServices.engine.cancel(runID: record.id)
                                    }
                                }
                            }
                        }
                    }

                    validationView

                    nodeEditor(workflow: workflow)

                    triggerEditor(workflow: workflow)

                    if let record = runRecord {
                        runResultView(record)
                    }
                    if let message = statusMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("选择或创建工作流", systemImage: "flowchart")
        }
    }

    private var validationView: some View {
        Group {
            if validationErrors.isEmpty {
                Label("校验通过", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(validationErrors.enumerated()), id: \.offset) { _, error in
                        Label(String(describing: error), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: - 节点编辑

    private func nodeEditor(workflow: Binding<FlowWorkflow>) -> some View {
        GroupBox("节点（按顺序执行；前一节点输出自动接入下一节点输入）") {
            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    ForEach(descriptors) { descriptor in
                        Button(descriptor.name) {
                            workflow.wrappedValue.nodes.append(FlowNode(
                                actionID: descriptor.id,
                                parameters: Dictionary(
                                    uniqueKeysWithValues: descriptor.parameters.map { ($0.key, $0.defaultValue) })))
                            validate()
                        }
                    }
                } label: {
                    Label("添加动作节点", systemImage: "plus")
                }

                if workflow.wrappedValue.nodes.isEmpty {
                    Text("尚未添加节点").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(workflow.wrappedValue.nodes.indices, id: \.self) { index in
                    nodeRow(index: index, node: workflow.nodes[index])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func nodeRow(index: Int, node: Binding<FlowNode>) -> some View {
        let descriptor = FlowServices.registry.descriptor(for: node.wrappedValue.actionID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(index + 1).").font(.caption.monospaced()).foregroundStyle(.tertiary)
                Text(descriptor?.name ?? node.wrappedValue.actionID).font(.callout.bold())
                Text(descriptor?.module ?? "").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if index > 0 {
                    Button {
                        node.wrappedValue.position = node.wrappedValue.position
                        FlowServicesUpward.moveUp(&selected!.nodes, index)
                        validate()
                    } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.link)
                }
                Button(role: .destructive) {
                    selected?.nodes.remove(at: index)
                    validate()
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.link)
            }
            // 参数表单（由描述符驱动）
            if let descriptor {
                ForEach(descriptor.parameters, id: \.key) { parameter in
                    HStack {
                        Text(parameter.label).font(.caption).frame(width: 90, alignment: .leading)
                        ParameterField(parameter: parameter, value: Binding(
                            get: { node.wrappedValue.parameters[parameter.key] ?? parameter.defaultValue },
                            set: { node.wrappedValue.parameters[parameter.key] = $0; validate() }))
                    }
                }
            }
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func triggerEditor(workflow: Binding<FlowWorkflow>) -> some View {
        GroupBox("触发方式") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("触发", selection: Binding(
                    get: { workflow.wrappedValue.trigger },
                    set: { workflow.wrappedValue.trigger = $0; validate() })) {
                    Text("手动").tag(FlowWorkflow.Trigger.manual)
                    Text("文件夹事件").tag(
                        FlowWorkflow.Trigger.folderEvent(path: triggerFolderPath(workflow.wrappedValue), debounceSeconds: 2))
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                if case .folderEvent(let path, _) = workflow.wrappedValue.trigger {
                    HStack {
                        Text(path.isEmpty ? "未设置文件夹" : path)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        Button("选择文件夹…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.begin { response in
                                guard response == .OK, let url = panel.url else { return }
                                workflow.wrappedValue.trigger = .folderEvent(path: url.path, debounceSeconds: 2)
                                validate()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func triggerFolderPath(_ workflow: FlowWorkflow) -> String {
        if case .folderEvent(let path, _) = workflow.trigger { return path }
        return ""
    }

    private func runResultView(_ record: FlowRunRecord) -> some View {
        GroupBox("运行结果：\(record.status.rawValue)（\(String(format: "%.2f", record.finishedAt?.timeIntervalSince(record.startedAt) ?? 0))s）") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(record.nodeResults.enumerated()), id: \.offset) { index, node in
                    HStack {
                        Image(systemName: statusIcon(node.status))
                            .foregroundStyle(statusColor(node.status))
                        Text("\(index + 1). \(node.actionID)").font(.caption)
                        if let message = node.message {
                            Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                }
                ForEach(Array(record.log.suffix(4).enumerated()), id: \.offset) { _, entry in
                    Text("[\(entry.time.formatted(date: .omitted, time: .standard))] \(entry.message)")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - 动作

    private func reload() async {
        workflows = (try? await FlowServices.store.loadAll()) ?? []
        descriptors = FlowServices.registry.allDescriptors
    }

    private func createNew() {
        let workflow = FlowWorkflow(name: "新工作流")
        Task {
            workflows.insert(workflow, at: 0)
            selected = workflow
        }
    }

    private func validate() {
        guard let selected else { return }
        validationErrors = FlowValidator.validate(workflow: selected, registry: FlowServices.registry)
    }

    private func save() async {
        guard let selected else { return }
        try? await FlowServices.store.save(selected)
        await reload()
        statusMessage = "已保存"
        setupWatcher(for: selected)
    }

    private func run(dryRun: Bool) async {
        guard let workflow = selected else { return }
        running = true
        defer { running = false }
        let options = FlowEngine.Options(dryRun: dryRun)
        let record = await FlowServices.engine.run(workflow: workflow, options: options)
        runRecord = record
        if !dryRun {
            await FlowServices.store.recordRun(record)
        }
        statusMessage = "运行结束：\(record.status.rawValue)"
    }

    private func setupWatcher(for workflow: FlowWorkflow) {
        // 移除旧监视器
        if let old = FlowServices.watchers[workflow.id] {
            old.stop()
            FlowServices.watchers[workflow.id] = nil
        }
        guard case .folderEvent(let path, let debounce) = workflow.trigger, !path.isEmpty else { return }
        let watcher = FolderWatcher(path: path, debounceSeconds: debounce) { [workflow] in
            let record = await FlowServices.engine.run(workflow: workflow)
            await FlowServices.store.recordRun(record)
        }
        watcher.start()
        FlowServices.watchers[workflow.id] = watcher
    }

    private func export(_ workflow: FlowWorkflow) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(workflow.name).flow.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? workflow.encoded() else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url),
                  let workflow = try? FlowWorkflow.decode(data) else {
                    statusMessage = "导入失败（格式不支持或文件损坏）"
                    return
            }
            Task {
                try? await FlowServices.store.save(workflow)
                await reload()
                statusMessage = "已导入：\(workflow.name)"
            }
        }
    }

    private func triggerLabel(_ trigger: FlowWorkflow.Trigger) -> String {
        switch trigger {
        case .manual: return "手动"
        case .folderEvent: return "文件夹事件"
        }
    }

    private func statusIcon(_ status: FlowRunRecord.NodeResult.NodeStatus) -> String {
        switch status {
        case .pending: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "forward.end"
        case .cancelled: return "minus.circle"
        }
    }

    private func statusColor(_ status: FlowRunRecord.NodeResult.NodeStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .running: return .blue
        case .finished: return .green
        case .failed: return .red
        case .skipped: return .orange
        case .cancelled: return .orange
        }
    }
}

/// 节点顺序调整辅助。
enum FlowServicesUpward {
    @MainActor
    static func moveUp(_ nodes: inout [FlowNode], _ index: Int) {
        guard index > 0 else { return }
        nodes.swapAt(index, index - 1)
    }
}

/// 参数编辑控件（按描述符类型）。
struct ParameterField: View {
    let parameter: ParameterDescriptor
    @Binding var value: ParameterValue

    var body: some View {
        switch parameter.kind {
        case .int:
            TextField(parameter.label, text: Binding(
                get: { "\(value.intParameter ?? Int(parameter.defaultValue.intParameter ?? 0))" },
                set: { if let number = Int($0) { value = .int(number) } }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
        case .double:
            TextField(parameter.label, text: Binding(
                get: { "\(value.doubleParameter ?? 0)" },
                set: { if let number = Double($0) { value = .double(number) } }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
        case .string, .folder:
            TextField(parameter.label, text: Binding(
                get: { value.stringParameter ?? "" },
                set: { value = .string($0) }))
                .textFieldStyle(.roundedBorder)
        case .option:
            Picker(parameter.label, selection: Binding(
                get: { value.stringParameter ?? parameter.defaultValue.stringParameter ?? "" },
                set: { value = .string($0) })) {
                ForEach(parameter.allowedOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .frame(width: 130)
        case .bool:
            Toggle(parameter.label, isOn: Binding(
                get: { value.boolParameter ?? false },
                set: { value = .bool($0) }))
        }
    }
}

extension ParameterValue {
    var intParameter: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
    var doubleParameter: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }
    var stringParameter: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    var boolParameter: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
