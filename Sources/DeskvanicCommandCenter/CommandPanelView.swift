import AppKit
import DeskvanicCore
import SwiftUI

/// 面板视图模型：查询、候选、选中项、错误反馈。
@MainActor
public final class CommandPanelModel: ObservableObject {
    @Published public var query = ""
    @Published public private(set) var results: [ScoredCommand] = []
    @Published public var selectedIndex = 0
    @Published public private(set) var searching = false
    @Published public private(set) var errorMessage: String?

    private var searchTask: Task<Void, Never>?
    private var debounceNanos: UInt64 = 120_000_000

    public init() {}

    public func prepareForDisplay() {
        query = ""
        results = []
        selectedIndex = 0
        errorMessage = nil
        refresh(query: "")
    }

    public func panelHidden() {
        searchTask?.cancel()
    }

    public func refresh(query: String) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanos ?? 120_000_000)
            guard !Task.isCancelled else { return }
            self?.searching = true
            let results = await CommandCenterEngine.shared.search(query: query)
            guard !Task.isCancelled else { return }
            self?.searching = false
            self?.results = results
            self?.selectedIndex = min(self?.selectedIndex ?? 0, max(0, results.count - 1))
        }
    }

    public func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    public func executeSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        let command = results[selectedIndex].command
        Task {
            let result = await CommandCenterEngine.shared.execute(command)
            switch result {
            case .success:
                CommandPanelController.shared.hidePanel()
            case .failed(let message):
                errorMessage = message
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                errorMessage = nil
            }
        }
    }
}

/// 面板主视图。
struct CommandPanelView: View {
    @ObservedObject var model: CommandPanelModel
    @EnvironmentObject var controller: CommandPanelController
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("搜索命令、应用、文件…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { model.executeSelected() }
                    .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                    .onKeyPress(.escape) { controller.hidePanel(); return .handled }
                    .onChange(of: model.query) { _, newQuery in
                        model.refresh(query: newQuery)
                        model.selectedIndex = 0
                    }
                if model.searching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 18)
                Divider()
            }

            if model.results.isEmpty && !model.searching {
                VStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? "输入以搜索；> 前缀仅搜命令，app 前缀仅搜应用" : "没有匹配的结果")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                            ResultRow(item: item, isSelected: index == model.selectedIndex) {
                                model.selectedIndex = index
                                model.executeSelected()
                            }
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 680, height: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .onAppear {
            searchFocused = true
        }
    }
}

struct ResultRow: View {
    let item: ScoredCommand
    let isSelected: Bool
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.command.icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(isSelected ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.command.title)
                    .lineLimit(1)
                if let subtitle = item.command.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(kindLabel(item.command.kind))
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quinary, in: Capsule())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        .onTapGesture { onActivate() }   // 单击执行（同时更新选中态）
    }

    private func kindLabel(_ kind: CommandItem.Kind) -> String {
        switch kind {
        case .tool: return "工具"
        case .action: return "动作"
        case .application: return "应用"
        case .file: return "文件"
        case .clip: return "剪贴板"
        case .vaultItem: return "资料"
        case .webURL: return "链接"
        }
    }
}
