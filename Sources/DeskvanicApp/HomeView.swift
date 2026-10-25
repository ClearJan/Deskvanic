import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// 首页：工具快速入口、最近任务、运行状态。
struct HomeView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var registry = ToolRegistry.shared
    @State private var history: [TaskQueue.JobHistoryItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("你的 Mac，一个工作空间")
                        .font(.largeTitle.bold())
                    Text("Your Mac. One workspace.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if let error = appModel.bootError {
                    ErrorBanner(message: error)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("工具").font(.title2.bold())
                    if registry.entries.isEmpty {
                        Text("核心服务已就绪，工具模块正在装配中。")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                            ForEach(registry.entries) { entry in
                                ToolCard(entry: entry)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("最近任务").font(.title2.bold())
                    if history.isEmpty {
                        Text("暂无任务记录")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(history.suffix(8).reversed())) { job in
                            HStack {
                                Image(systemName: Self.icon(for: job.state))
                                    .foregroundStyle(Self.color(for: job.state))
                                VStack(alignment: .leading) {
                                    Text(job.title).lineLimit(1)
                                    if let error = job.errorText {
                                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(Self.stateLabel(job.state))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Deskvanic")
        .task {
            history = await TaskQueue.shared.historyItems
            for await _ in EventBus.shared.events(matching: EventTopics.jobUpdated) {
                history = await TaskQueue.shared.historyItems
            }
        }
    }

    static func icon(for state: TaskQueue.JobState) -> String {
        switch state {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    static func color(for state: TaskQueue.JobState) -> Color {
        switch state {
        case .queued: return .secondary
        case .running: return .blue
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    static func stateLabel(_ state: TaskQueue.JobState) -> String {
        switch state {
        case .queued: return "排队中"
        case .running: return "执行中"
        case .finished: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

struct ToolCard: View {
    let entry: ToolEntry

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .deskvanicOpenTool, object: nil, userInfo: ["tool": entry.id])
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.icon)
                    .font(.title2)
                    .frame(width: 40, height: 40)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline)
                    Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading) {
                Text("初始化遇到问题").font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
