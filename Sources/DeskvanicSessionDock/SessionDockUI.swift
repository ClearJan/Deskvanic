import AppKit
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// SessionDock 服务装配点。
@MainActor
public enum SessionDockServices {
    public static var store = WorkspaceStore(database: Database(url: AppEnvironment.databaseURL))

    public static func inject(store newStore: WorkspaceStore) {
        store = newStore
    }
}

/// SessionDock 主界面：工作空间保存/启动/摆窗。
public struct SessionDockView: View {
    @State private var workspaces: [LayoutEngine.Workspace] = []
    @State private var statusMessage: String?
    @State private var newWorkspaceName = ""
    @State private var hasAccessibility = LayoutEngine.hasAccessibilityPermission()
    @State private var capturedWindows: [LayoutEngine.WindowSnapshot] = []

    public init() {}

    public var body: some View {
        ToolContainer("桌面工作空间", subtitle: "SessionDock · 一键启动一组应用并摆放窗口") {
            VStack(alignment: .leading, spacing: 16) {
                if !hasAccessibility {
                    permissionBanner
                }

                createSection
                workspaceList
                if let message = statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await reload() }
    }

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("需要辅助功能权限才能读取与摆放窗口").font(.callout.bold())
                Text("授权后 Deskvanic 可以保存/恢复窗口位置；只能移动窗口，无法恢复应用内部状态。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("去系统设置") {
                Task { _ = await Permissions.request(.accessibility) }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var createSection: some View {
        GroupBox("保存当前窗口布局为工作空间") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("工作空间名称（如：写作 / 开发 / 会议）", text: $newWorkspaceName)
                        .textFieldStyle(.roundedBorder)
                    Button("刷新当前窗口列表") { capture() }
                    Button("保存工作空间") { saveWorkspace() }
                        .disabled(newWorkspaceName.isEmpty || capturedWindows.isEmpty)
                }
                if capturedWindows.isEmpty {
                    Text("点击「刷新当前窗口列表」以捕获当前所有可见窗口。")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text("将捕获 \(capturedWindows.count) 个窗口：\(capturedWindows.prefix(4).map(\.appName).joined(separator: "、"))\(capturedWindows.count > 4 ? " 等" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("说明：只保存窗口位置与应用归属；应用内部未保存状态无法恢复；不受辅助功能控制的应用会被如实报告。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var workspaceList: some View {
        GroupBox("我的工作空间") {
            VStack(alignment: .leading, spacing: 10) {
                if workspaces.isEmpty {
                    Text("暂无工作空间").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                    HStack {
                        Image(systemName: "rectangle.split.2x1")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.name).font(.callout.bold())
                            Text("\(workspace.windows.count) 个窗口 · \(workspace.apps.count) 个应用")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("启动") { Task { await activate(workspace) } }
                        Button("重新摆放窗口") { Task { await relayout(workspace) } }
                        Button(role: .destructive) {
                            Task {
                                workspaces.remove(at: index)
                                await SessionDockServices.store.save(workspaces)
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.link)
                    }
                    .padding(6)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - 动作

    private func reload() async {
        workspaces = await SessionDockServices.store.load()
        hasAccessibility = LayoutEngine.hasAccessibilityPermission()
    }

    private func capture() {
        capturedWindows = LayoutEngine.captureWindows()
        hasAccessibility = LayoutEngine.hasAccessibilityPermission()
        if capturedWindows.isEmpty {
            statusMessage = "没有捕获到可控窗口（可能缺少辅助功能权限，或当前窗口都不满足条件）"
        }
    }

    private func saveWorkspace() {
        let apps = Array(Set(capturedWindows.compactMap(\.bundleID)))
        let workspace = LayoutEngine.Workspace(
            name: newWorkspaceName, apps: apps, windows: capturedWindows)
        Task {
            var updated = await SessionDockServices.store.load()
            updated.append(workspace)
            await SessionDockServices.store.save(updated)
            workspaces = updated
            newWorkspaceName = ""
            capturedWindows = []
            statusMessage = "工作空间「\(workspace.name)」已保存"
        }
    }

    private func activate(_ workspace: LayoutEngine.Workspace) async {
        statusMessage = "正在启动应用…"
        let failures = await LayoutEngine.launch(apps: workspace.apps)
        // 等待窗口就绪后摆放
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await relayout(workspace)
        if !failures.isEmpty {
            statusMessage = "启动完成；未能启动：\(failures.joined(separator: "、"))"
        }
    }

    private func relayout(_ workspace: LayoutEngine.Workspace) async {
        var results: [String] = []
        for snapshot in workspace.windows {
            guard let bundleID = snapshot.bundleID else {
                results.append("\(snapshot.appName)：无 bundleID")
                continue
            }
            switch LayoutEngine.placeWindow(appBundleID: bundleID, windowTitle: snapshot.windowTitle, to: snapshot.frame) {
            case .success:
                break
            case .failure(let error):
                switch error {
                case .accessibilityDenied:
                    statusMessage = "辅助功能权限被拒绝，无法摆放窗口"
                    hasAccessibility = false
                    return
                case .appNotRunning:
                    results.append("\(snapshot.appName)：未运行")
                case .noWindows:
                    results.append("\(snapshot.appName)：无窗口")
                case .axError:
                    results.append("\(snapshot.appName)：系统拒绝控制（应用可能不支持）")
                }
            }
        }
        statusMessage = results.isEmpty ? "窗口布局已恢复" : "布局完成，部分窗口未恢复：" + results.joined(separator: "；")
        await reload()
    }
}
