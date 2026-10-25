import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// 主窗口：侧边栏（首页 / 分组工具），内容区承载各模块视图。
struct MainWindow: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var registry = ToolRegistry.shared
    @State private var selection: String? = "home"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("首页", systemImage: "house")
                        .tag("home")
                }
                ForEach(ToolSection.allCases, id: \.self) { section in
                    let tools = registry.entries.filter { $0.section == section }
                    if !tools.isEmpty {
                        Section(section.rawValue) {
                            ForEach(tools) { tool in
                                Label(tool.name, systemImage: tool.icon)
                                    .tag(tool.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            if let selection {
                detailView(for: selection)
            } else {
                ContentUnavailableView("请选择一个项目", systemImage: "sidebar.leading")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deskvanicOpenTool)) { note in
            if let id = note.userInfo?["tool"] as? String { selection = id }
        }
    }

    @ViewBuilder
    private func detailView(for id: String) -> some View {
        if id == "home" {
            HomeView()
        } else if let tool = registry.module(id: id) {
            tool.makeView()
        } else {
            ContentUnavailableView("未找到工具", systemImage: "questionmark.square.dashed")
        }
    }
}
