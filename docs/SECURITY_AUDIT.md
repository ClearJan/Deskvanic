# Deskvanic 安全审计报告

> 审计时间：2026-10-25 · 审计方式：代码审查 + 自动化安全测试 + 独立 Agent 交叉复核
> 结论先行：**未发现 P0 级发布阻断缺陷**。以下按维度记录证据与残留风险。

## 1. 数据可靠性（任务书第 9/20 节）

| 要求 | 实现 | 证据 |
|---|---|---|
| 原文件保留 | 所有处理操作输出到新文件 | E2E 断言源文件 SHA-256 不变（ZIPTests/ImageEngineTests） |
| 删除可恢复 | 用户数据删除统一走 `FileSafety.moveToTrash`（NSWorkspace.recycle） | CleanUI 重复文件、OrganizeEngine 跨卷移动均走废纸篓；单测覆盖 |
| removeItem 使用场景 | 仅限：① 应用自身产物（Clips/Guides/VoiceMemos 的库内副本） ② 输出校验失败后的残留清理 ③ 用户明确确认后的"复制进库副本"删除 | 全部 25 处逐一核对，无用户原始文件直接删除 |
| 同名冲突 | `FileSafety.uniqueDestination`（"name 2.ext"） | ZIP 解压/整理执行/导出均使用；单测 `outputsConflictHandledByUniqueDestination` |
| 输出校验 | `FileSafety.validateOutput`（存在/非空/可读）+ 格式级复核（PDF 重开页数、图片重读尺寸、音视频重解码时长） | 各引擎测试 |
| 失败清理 | 临时产物失败即删除 | ImageEngine/PDFEngine/ZIPArchive `try? removeItem` 路径 |
| 审计日志 | 整理/删除/导出/传输入 audit_log | CleanTests 断言 5 条 clean.move 记录 |

## 2. 输入与路径安全

- **路径穿越**：`FileSafety.isContained`（逐组件解析符号链接——修复了 `URL.resolvingSymlinksInPath` 对不存在末段不解析的系统行为差异）+ `validateRelativeEntry`（绝对路径/`..`/盘符拒绝）。单测：`pathContainmentSymlinkEscape`、ZIP 恶意条目、NearLink 下载 `../../etc/passwd`。
- **ZIP 炸弹**：单文件 2GB / 总量 10GB 上限；CRC-32 全量校验；symlink 条目拒绝。测试覆盖。
- **SQL 注入**：全部 46 处查询参数化（`?` 占位 + bind）；FTS 查询逐词转义（`queryInjectionIsNeutralized` 测试）；动态 IN 子句用占位符展开而非值拼接。审查未发现值拼接进 SQL 的路径。
- **正则注入**：查找替换的用户正则 `NSRegularExpression` 包裹 try/catch，非法正则报 `invalidInput` 不崩溃（`invalidRegexThrowsNotCrashes`）。
- **Markdown/HTML**：自研渲染器无 HTML 解释；链接 scheme 白名单（http/https/mailto），`javascript:` 降级纯文本（`dangerousSchemeDropped`）；QR 内容同样降级（`dangerousSchemeDowngrades`）。导出 HTML 时用户文本经 `escapeHTML`。

## 3. 网络安全（NearLink）

- 所有业务路由强制令牌校验（测试：无令牌/错令牌 → 403）。
- 令牌：`SecRandomCopyBytes` 128bit 随机，30 分钟过期（过期测试覆盖），UI 一键重置。
- **如实声明（不做虚假宣传）**：传输为局域网 HTTP + 令牌，**不是 TLS，不是端到端加密**——UI 常驻安全说明、本文档、README 三处明示。用户文档建议仅在可信网络使用。
- 令牌比较为常量时间实现（防时序侧信道）；同时连接数上限 16；下载采用 RFC 5987 编码文件名 + 流式分块发送（无 2× 内存峰值）；上传先写唯一临时名再改名（TOCTOU 防护）；/text 写盘失败返回 500。〔独立审计 P1/P2/P3 修复，commit dc48db7 与后续〕
- 请求体上限 500MB；下载 id 禁止路径分隔符；文件名安全化处理。

## 4. 隐私

- **OCR**：Vision 本机执行，无网络上传（Apple 框架行为 + 代码无上传路径）。
- **语音**：录音仅存本机；`requiresOnDeviceRecognition` 优先；不支持设备端的语言在 UI 明确标注"将使用服务器识别"，不静默上传。
- **元数据剥离**：输出后重新 inspect 断言 GPS/IPTC 为空（`stripMetadataRemovesGPSAndEXIF`）——隐私承诺经测试验证而非口头保证。
- **剪贴板**：跳过 `org.nspasteboard.Concealed/Transient` 私密标记；历史可一键清空、可暂停、保留期可配。
- **日志**：os_log + 本地文件，不含用户文件内容（仅路径与状态）；无遥测、无网络上报。
- **权限最小化**：屏幕录制/麦克风/语音识别/辅助功能/通知均为按需请求 + 状态展示；未授权时功能明确降级提示，不绕过、不重复骚扰。

## 5. 硬编码与供应链

- 无硬编码密钥/令牌/密码（grep 审计通过；令牌全部运行时生成）。
- **零第三方依赖**：全部 Apple 系统框架（Foundation/AppKit/SwiftUI/SQLite3/Compression/ImageIO/Vision/Speech/AVFoundation/Network/EventKit/QuickLook/PDFKit/UserNotifications/Carbon）。无供应链投毒面。

## 6. 残留风险（P2/P3，如实记录）

| 级别 | 风险 | 缓解 |
|---|---|---|
| P2 | NearLink HTTP 明文传输在恶意局域网可被嗅探 | 令牌门槛 + UI 显著警示 + 文档建议可信网络；TLS 支持列入路线图 |
| P2 | 命令面板文件搜索依赖用户手动授权目录，若用户授权整个用户目录则扫描面大 | 扫描有深度/数量上限，不跟随符号链接 |
| P3 | `simulated paste`（⌘V 模拟）需辅助功能权限，权限较宽 | 仅在用户明确点击"插入/粘贴"按钮时触发 |
| P3 | 网页抓取响应体上限 20MB | 超限明确报错（审计 #21 已加） |
| P3 | GuideCraft 敏感信息检查为 OCR 启发式 | UI 明示"需人工复核"，非隐私保证 |

## 7. 发布阻断项核对（任务书 20 节）

| 阻断项 | 状态 |
|---|---|
| 正常操作造成不可恢复数据丢失 | ✅ 未发现（删除全部走废纸篓/副本删除） |
| 遮盖后可恢复却宣称安全 | ✅ 模糊为真像素破坏（测试验证），无仅覆盖图层的实现 |
| 无授权采集屏幕/麦克风/文件 | ✅ 全部按需请求，未授权明确降级 |
| 默认上传本地数据 | ✅ 无任何遥测/上传路径 |
| 网络接口未授权读写文件 | ✅ 令牌强制 + 路径白名单 |
| 工作流意外执行任意命令 | ✅ 无 Shell 节点；动作全部为注册的编译期实现 |
| 安装程序破坏系统 | ✅ .app 拖拽安装，无系统写入（仅标准 Application Support） |
| 常见输入反复崩溃 | ✅ 215 项测试 + 模糊/恶意输入用例通过 |
| 签名/更新完整性缺陷 | ✅ ad-hoc 签名如实标注；无自动更新机制（未启用不安全更新源） |
