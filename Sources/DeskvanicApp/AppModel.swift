import DeskvanicCapture
import DeskvanicClipVault
import DeskvanicCommandCenter
import DeskvanicClean
import DeskvanicFlow
import DeskvanicGuide
import DeskvanicPaper
import DeskvanicWeb
import DeskvanicMedia
import DeskvanicNearLink
import DeskvanicSessionDock
import DeskvanicVoice
import DeskvanicCore
import DeskvanicFileStudio
import DeskvanicQuickTools
import DeskvanicVault
import DeskvanicUIShared
import SwiftUI

/// 应用组合根：创建并持有核心服务实例，向各模块分发依赖。
/// 模块之间不直接互相引用，统一经由这里注入。
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let database: Database
    let searchIndex: SearchIndex
    let settings: SettingsStore<AppSettings>
    let auditLog: AuditLog
    let bookmarks: BookmarkStore

    @Published private(set) var bootError: String?
    @Published private(set) var booted = false

    private init() {
        let db = Database(url: AppEnvironment.databaseURL)
        database = db
        searchIndex = SearchIndex(database: db)
        let settings = SettingsStore(defaults: AppSettings(), url: AppEnvironment.settingsURL)
        self.settings = settings
        auditLog = AuditLog(database: db)
        bookmarks = BookmarkStore()

        // 向模块注入共享实例（命令中心等模块经由 AppServices 读取）
        AppServices.settingsStore = settings

        registerModules()
    }

    /// 注册所有工具模块；新增模块在此追加。
    private func registerModules() {
        let registry = ToolRegistry.shared
        registry.register(CommandCenterTool())
        registry.register(ClipVaultTool())
        registry.register(CaptureTool())
        registry.register(VaultTool())
        registry.register(FileStudioTool())
        registry.register(QuickToolsEntry())
        registry.register(CleanTool())
        registry.register(NearLinkTool())
        registry.register(VoiceTool())
        registry.register(SessionDockTool())
        registry.register(FlowTool())
        registry.register(MediaTool())
        registry.register(GuideTool())
        registry.register(PaperTool())
        registry.register(WebVaultTool())
    }

    func boot() async {
        guard !booted else { return }
        do {
            try await database.open()
            try await database.migrate(DeskvanicSchema.migrations + [ClipVaultSchema.migration, CaptureSchema.migration, VaultSchema.migration, CleanSchema.migration, NearLinkSchema.migration, VoiceSchema.migration, FlowSchema.migration, GuideSchema.migration, PaperSchema.migration, WebVaultSchema.migration])
            booted = true

            // 注入模块共享服务
            let clipStore = ClipStore(database: database, index: searchIndex)
            let settingsStore = settings
            ClipVaultServices.settingsStore = settingsStore
            CaptureServices.inject(store: CaptureStore(database: database, index: searchIndex))
            VaultServices.inject(store: VaultStore(database: database, index: searchIndex), database: database)
            FileStudioServices.inject(database: database)
            CleanServices.inject(database: database, auditLog: auditLog)
            NearLinkServices.inject(store: NearLinkStore(database: database))
            VoiceServices.inject(store: VoiceStore(database: database))
            SessionDockServices.inject(store: WorkspaceStore(database: database))
            FlowServices.inject(store: FlowStore(database: database))
            FlowActions.registerAll(into: FlowServices.registry)
            GuideServices.inject(store: GuideStore(database: database))
            PaperServices.inject(store: PaperStore(database: database))
            WebVaultServices.inject(store: WebVaultStore(database: database))
            let db = database
            let index = searchIndex
            VaultBridge.saveHandler = { payload in
                let item = VaultItem(kind: .text, title: payload.title,
                                     contentText: payload.content, tags: payload.tags)
                let vaultStore = VaultStore(database: db, index: index)
                try await vaultStore.add(item)
            }
            ClipVaultServices.inject(store: clipStore) {
                settingsStore.snapshot.clipVault
            }
            if !settingsStore.snapshot.clipVault.pauseMonitoring {
                ClipVaultServices.monitor.start()
            }

            await syncToolCommands()
            await syncClipProvider()
            Log.info("Deskvanic 启动完成 v\(AppEnvironment.appVersion)", category: .app)
            await auditLog.record(action: "app.launch", outcome: "ok", detail: AppEnvironment.appVersion)
        } catch {
            bootError = String(describing: error)
            Log.error("核心服务初始化失败: \(String(describing: error))", category: .core)
        }
    }

    /// 剪贴板历史接入命令面板（动态 provider）。
    private func syncClipProvider() async {
        let store = ClipVaultServices.store
        await CommandRegistry.shared.registerProvider(id: "clips") { query in
            guard let entries = try? await store.search(query, limit: 8) else { return [] }
            return entries.map { entry in
                CommandItem(
                    id: "clip.\(entry.id)",
                    title: entry.preview.isEmpty ? entry.kind.displayName : entry.preview,
                    subtitle: "剪贴板 · 复制",
                    kind: .clip,
                    icon: "doc.on.clipboard",
                    payload: entry.id)
            }
        }
    }

    /// 把已注册工具同步到命令中心（工具面板可搜索打开所有工具）。
    private func syncToolCommands() async {
        let entries = ToolRegistry.shared.entries
        let items = entries.map { entry in
            CommandItem(
                id: "tool.\(entry.id)",
                title: entry.name,
                subtitle: "打开工具",
                kind: .tool,
                icon: entry.icon,
                payload: entry.id)
        }
        await CommandRegistry.shared.register(items)
    }
}
