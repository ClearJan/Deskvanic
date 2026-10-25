import DeskvanicCore
import ServiceManagement
import SwiftUI

/// 统一设置窗口：通用、权限、数据。
struct GeneralSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var settings: AppSettings = AppSettings()

    var body: some View {
        TabView {
            Form {
                Picker("界面语言", selection: Binding(
                    get: { settings.general.language },
                    set: { newValue in update { $0.general.language = newValue } })) {
                    Text("跟随系统").tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                Toggle("登录时启动 Deskvanic", isOn: Binding(
                    get: { settings.general.launchAtLogin },
                    set: { newValue in update { $0.general.launchAtLogin = newValue } }))
                Toggle("在菜单栏保留图标", isOn: Binding(
                    get: { settings.general.keepInMenuBar },
                    set: { newValue in update { $0.general.keepInMenuBar = newValue } }))
            }
            .padding(20)
            .frame(width: 460)
            .tabItem { Label("通用", systemImage: "gearshape") }

            PermissionsSettingsView()
                .tabItem { Label("权限", systemImage: "lock.shield") }

            DataSettingsView()
                .tabItem { Label("数据", systemImage: "externaldrive") }
        }
        .onAppear { settings = appModel.settings.snapshot }
    }

    private func update(_ mutate: (inout AppSettings) -> Void) {
        let before = appModel.settings.snapshot.general.launchAtLogin
        appModel.settings.update(mutate)
        settings = appModel.settings.snapshot
        let after = appModel.settings.snapshot.general.launchAtLogin
        if before != after { handleLaunchAtLogin() }
    }

    private func handleLaunchAtLogin() {
        let enabled = appModel.settings.snapshot.general.launchAtLogin
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 未打包为 .app 时（开发模式运行）注册会失败，如实记录即可。
            Log.warning("登录启动设置失败: \(String(describing: error))", category: .app)
        }
    }
}

struct PermissionsSettingsView: View {
    @State private var statuses: [PermissionKind: PermissionStatus] = [:]

    var body: some View {
        Form {
            ForEach(PermissionKind.allCases, id: \.self) { kind in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.displayName)
                        Text(statusText(statuses[kind] ?? .notDetermined))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if statuses[kind] == .granted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("授权") { Task { await request(kind) } }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await refresh() }
    }

    private func refresh() async {
        for kind in PermissionKind.allCases {
            statuses[kind] = await Permissions.status(of: kind)
        }
    }

    private func request(_ kind: PermissionKind) async {
        _ = await Permissions.request(kind)
        await refresh()
    }

    private func statusText(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: return "已授权"
        case .denied: return "已拒绝（需在系统设置中开启）"
        case .notDetermined: return "尚未请求"
        case .restricted: return "受限"
        }
    }
}

struct DataSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var backupMessage: String?

    var body: some View {
        Form {
            LabeledContent("数据库位置") {
                Text(AppEnvironment.databaseURL.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            HStack {
                Button("备份数据库…") { backup() }
                Button("打开数据目录") {
                    NSWorkspace.shared.open(AppEnvironment.supportDirectory)
                }
                Button("打开日志目录") {
                    NSWorkspace.shared.open(AppEnvironment.logsDirectory)
                }
            }
            if let backupMessage {
                Text(backupMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func backup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = "Deskvanic-Backup-\(Int(Date().timeIntervalSince1970)).sqlite"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await appModel.database.backup(to: url)
                    backupMessage = "备份完成: \(url.lastPathComponent)"
                } catch {
                    backupMessage = "备份失败: \(String(describing: error))"
                }
            }
        }
    }
}
