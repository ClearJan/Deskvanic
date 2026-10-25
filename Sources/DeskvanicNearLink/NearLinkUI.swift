import AppKit
import DeskvanicCore
import DeskvanicUIShared
import DeskvanicQuickTools
import SwiftUI

/// NearLink 服务装配点。
@MainActor
public enum NearLinkServices {
    public static var store = NearLinkStore(database: Database(url: AppEnvironment.databaseURL))
    public static let server = NearLinkServer()

    public static func inject(store newStore: NearLinkStore) {
        store = newStore
        server.onTransfer = { direction, filename, bytes, peer in
            Task { await store.record(direction, filename: filename, bytes: bytes, peer: peer) }
        }
    }
}

/// NearLink 主界面：开关、二维码邀请、共享文件管理、传输记录。
public struct NearLinkToolView: View {
    @StateObject private var model = NearLinkModel()
    @State private var invitationQR: NSImage?
    @State private var invitationURL: String?
    @State private var records: [TransferRecord] = []
    @State private var sharedFiles: [String] = []
    @State private var statusMessage: String?

    public init() {}

    public var body: some View {
        ToolContainer("跨设备互传", subtitle: "NearLink · 局域网 + 访问令牌") {
            VStack(alignment: .leading, spacing: 18) {
                Toggle(isOn: Binding(
                    get: { model.isRunning },
                    set: { enabled in Task { await model.setRunning(enabled) } })) {
                    Label(model.isRunning ? "服务运行中（端口 \(model.port)）" : "服务已停止",
                          systemImage: "dot.radiowaves.left.and.right")
                }
                .toggleStyle(.switch)

                securityNotice

                if model.isRunning {
                    invitationSection
                }

                sharedSection
                recordsSection

                if let message = statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await reload() }
    }

    private var securityNotice: some View {
        Label("安全说明：传输通过局域网 HTTP + 随机访问令牌进行，不是加密通道也不是端到端加密；令牌有效期 30 分钟，可随时重置。请仅在可信网络中使用。",
              systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var invitationSection: some View {
        GroupBox("邀请手机/浏览器") {
            HStack(alignment: .top, spacing: 16) {
                if let invitationQR {
                    Image(nsImage: invitationQR)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 160, height: 160)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quinary)
                        .frame(width: 160, height: 160)
                        .overlay {
                            Text("二维码生成中…").font(.caption).foregroundStyle(.secondary)
                        }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("用手机相机扫码，或访问：").font(.callout)
                    if let invitationURL {
                        Text(invitationURL)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("重新生成令牌") { Task { await model.resetSession(); await refreshInvitation() } }
                        Button("打开共享目录") { NSWorkspace.shared.open(NearLinkServices.server.sharedDirectory) }
                        Button("打开接收目录") { NSWorkspace.shared.open(NearLinkServices.server.incomingDirectory) }
                    }
                    Text("手机上传的文件保存在接收目录；下方共享列表中的文件可从手机下载。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var sharedSection: some View {
        GroupBox("共享文件（从手机可下载）") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("添加共享文件…") { addSharedFile() }
                    Button("生成二维码") { Task { await refreshInvitation() } }
                    Spacer()
                    if sharedFiles.isEmpty {
                        Text("暂无共享文件").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                ForEach(sharedFiles, id: \.self) { name in
                    HStack {
                        Image(systemName: "doc")
                        Text(name).font(.callout).lineLimit(1)
                        Spacer()
                        Button("移除", role: .destructive) { removeShared(name) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var recordsSection: some View {
        GroupBox("传输记录") {
            VStack(alignment: .leading, spacing: 6) {
                if records.isEmpty {
                    Text("暂无传输记录").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(records.prefix(10)) { record in
                    HStack {
                        Image(systemName: record.direction.hasPrefix("receive") ? "arrow.down.circle" : "arrow.up.circle")
                            .foregroundStyle(record.direction.hasPrefix("receive") ? .green : .blue)
                        Text(record.filename).font(.caption).lineLimit(1)
                        Spacer()
                        Text(record.sizeBytes.formatted(.byteCount(style: .memory)))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(record.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - 动作

    private func refreshInvitation() async {
        if let url = await model.invitationURL() {
            invitationURL = url
            if let cg = try? QRCodeService.generate(payload: url, scale: 6) {
                invitationQR = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
            }
        }
    }

    private func addSharedFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "选择要从手机下载的文件（复制到共享目录）"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                let dest = FileSafety.uniqueDestination(
                    in: NearLinkServices.server.sharedDirectory, preferredName: url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: dest)
            }
            Task { await reload() }
        }
    }

    private func removeShared(_ name: String) {
        try? FileManager.default.removeItem(
            at: NearLinkServices.server.sharedDirectory.appendingPathComponent(name))
        Task { await reload() }
    }

    private func reload() async {
        records = await NearLinkServices.store.recent()
        sharedFiles = (try? FileManager.default.contentsOfDirectory(atPath: NearLinkServices.server.sharedDirectory.path))?
            .filter { !$0.hasPrefix(".") } ?? []
        if model.isRunning { await refreshInvitation() }
    }
}

/// NearLink 视图模型。
@MainActor
public final class NearLinkModel: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var port: UInt16 = 0

    public init() {}

    public func setRunning(_ enabled: Bool) async {
        let server = NearLinkServices.server
        if enabled {
            do {
                try server.start()
                _ = server.newSession()
                isRunning = true
                port = server.port
            } catch {
                Log.error("NearLink 启动失败: \(String(describing: error))", category: .network)
                isRunning = false
            }
        } else {
            server.stop()
            server.invalidateSession()
            isRunning = false
            port = 0
        }
    }

    public func resetSession() async {
        _ = NearLinkServices.server.newSession()
    }

    public func invitationURL() async -> String? {
        NearLinkServices.server.invitationURL()
    }
}
