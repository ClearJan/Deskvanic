# Deskvanic 架构说明（ARCHITECTURE.md）

## 总体形态

**模块化单体**：一个 `Deskvanic.app`，内含 1 个核心服务层 + 1 个共享 UI 层 + 12 个功能模块 + 1 个应用宿主。全部 Swift Package（SPM），无 Xcode 工程文件依赖，`swift build` 即可构建。

```
DeskvanicApp（宿主：组合根、主窗口、设置、菜单栏、模块适配器、Flow 动作注册）
  ├── DeskvanicUIShared（ToolRegistry/ToolSection/工具容器——模块间唯一共享 UI 协议）
  └── DeskvanicCore（核心服务层）
        Database(actor, SQLite+WAL, 版本化迁移 v1–v12, VACUUM 备份)
        SearchIndex(FTS5, CJK 逐字分词, 注入转义)
        TaskQueue(受控并发/取消/进度/历史)   EventBus(发布订阅)
        FileSafety(路径包含/符号链接逐组件解析/原子写/SHA-256/废纸篓)
        SettingsStore(防抖持久化)  Permissions(按需授权)  AuditLog
        UniversalModels(统一数据协议: ResourceRef/PortType/ActionDescriptor——V1 冻结)
        OCREngine(DateCodec/DateCodec 等)
功能模块（只依赖 Core/UIShared，互不依赖）：
  CommandCenter  ClipVault  Capture  FileStudio  Vault
  Clean  NearLink  SessionDock  Voice  Guide  Paper  Web  Media  Flow
```

## 关键决策（ADR 摘要）

| ADR | 决策 | 理由 |
|---|---|---|
| 001 | SPM 多 target 而非 Xcode 工程 | 命令行可复现构建；模块边界由编译器强制；无 xcodegen 依赖 |
| 002 | SQLite3 C API 自封装（actor 隔离）而非第三方 ORM | 零依赖；Swift 6 严格并发下 actor 封装最干净；迁移机制自主可控 |
| 003 | FTS5 + CJK 逐字切分 | unicode61 对中文整段成单 token；写入与查询双侧统一切分（已测） |
| 004 | 自研 ZIP 编解码 | Apple 无官方 ZIP API；零第三方依赖约束下手写容器格式，CRC/炸弹/穿越防护均有测试 |
| 005 | Carbon RegisterEventHotKey | macOS 公开 API 中唯一的全局快捷键方案；冲突检测显式上报 |
| 006 | 最小 HTTP 服务器（Network.framework） | 近场互传无需完整 Web 框架；令牌模型简单可审计 |
| 007 | FlowEngine 动作注册表由宿主注入 | 引擎与业务模块解耦；动作=真实模块函数，无演示逻辑；V1 冻结的 PortType/ActionDescriptor 契约 |
| 008 | Swift 6 严格并发全开（StrictConcurrency + swiftLanguageModes v6） | 任务书禁止大规模关闭检查；所有跨界状态 Sendable/actor 化 |

## 数据流

- **统一数据协议**（UniversalModels）：`ResourceRef`（文本/URL/文件/图片/PDF/OCR/工作流产物）跨模块传递；`PortType` 类型系统约束 FlowEngine 连线；`ActionDescriptor` 描述每个可编排动作的输入/输出/参数/权限。
- **事件总线**：`EventBus` 松耦合通知（capture.saved / clip.captured / vault.item.added / job.updated）。
- **存储**：单 SQLite 文件（WAL），v1–v12 迁移链，`VACUUM INTO` 备份；二进制产物落盘 `Application Support/Deskvanic/{Captures,VaultStorage,Transfers,VoiceMemos}`，数据库只存路径。

## 并发模型

- 全部共享可变状态在 actor 内（Database/SearchIndex/TaskQueue/各 Store）或锁保护（HotkeyManager/EventBus registry）。
- UI 层 @MainActor；跨界闭包只捕获 Sendable 值（识别回调先提取纯值再跨域）。
- 主线程无同步 IO（扫描/转码/OCR 全部异步 + TaskQueue）。
