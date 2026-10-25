# Deskvanic 已知问题与平台限制（KNOWN_ISSUES.md）

> 更新：2026-10-25 · 如实记录，区分"限制/待办/需人工验证"

## 平台限制（macOS 系统行为，非缺陷）

1. **剪贴板来源归属为启发式**：macOS 无公开 API 获取复制来源应用。采用"变化时刻的前台应用"归属，仅供"排除应用"参考，UI 已标注"来源（近似）"。
2. **私密剪贴板标记**：Concealed/Transient 类型跳过保存，但系统未强制——密码管理器若不设置标记，内容会进入历史（本地存储，不上传；可用保留期+清空控制）。
3. **JPEG 自动 EXIF**：ImageIO 为 JPEG 输出自动写入仅含创建时间的基础 EXIF。隐私剥离已验证 GPS/IPTC 清空；需要零 EXIF 请转 PNG（UI 与文档均已说明）。
4. **CGWindowListCreateImage 弃用警告**：macOS 14 起官方建议 ScreenCaptureKit。当前实现行为可预期（三种截图模式），迁移 ScreenCaptureKit 列入后续版本（截图管线已隔离在 CaptureEngine 单文件）。
5. **GIF/HEIC 转换取首帧**：动图转静态格式只保留第一帧，UI 明确标注。
6. **SessionDock 能力边界**：只能移动/缩放窗口，无法恢复应用内部未保存状态；部分应用不受辅助功能控制（逐一报告，不静默失败）。
7. **语音识别语言覆盖**：设备端识别以系统支持为准；不支持设备端的语种明确标注"将使用服务器识别"，不静默上传。
8. **SQLite FTS unicode61**：无内置中文分词；采用 CJK 逐字切分（写入/查询双侧一致），词组匹配正确但无词级语义（够用；未来可换 jieba 类分词器）。
9. **ZIP64 不支持**：单条目 >4GB 时明确报错（非静默失败）。
10. **GitHub Actions 无头 VM 无法运行 socket 与媒体类测试**（2026-10 记录）：GitHub 托管 macOS VM 上 NWListener 入站连接不会完成、虚拟 GPU 媒体栈缺失（`IOServiceMatching failed: AppleM2ScalerParavirtDriver`），且 `swift test` 执行层静默挂起（SwiftPM #8394 / runner-images #13096）。CI 采用 SwiftPM 同款执行器 `swiftpm-testing-helper` 逐套件运行；`NearLinkServer` 与 `端到端工作流` 两套件在检测到 `GITHUB_ACTIONS` 时带原因跳过（本地 macOS 全量通过，215 用例含 6 条端到端工作流）。这是 CI 环境的平台限制，不代表产品功能缺失——真实 Mac 上局域网传输与媒体处理均已验证。

## 待办（Backlog，非阻断）

10. FlowEngine 画布式编辑：当前为线性管线编辑器（引擎支持任意 DAG，UI 暂以顺序链呈现），可视化连线画布列入后续版本。
11. 命令面板 P95 精确压测：设计上满足 250ms（防抖 120ms + 缓存异步查询），GUI 自动化压测工具链待补。
12. 浏览器扩展（Web Vault 快捷收藏）：当前以"粘贴 URL + 命令面板"收藏；Safari 共享扩展需独立 App Extension 打包流程。
13. EventKit 日历同步：PaperTrail 到期提醒当前走通知中心；日历写入需用户单独授权，列为可选增强。
14. FTS 批量写入优化：万条逐条 upsert 5.5s；批量导入场景可改单事务（当前实时写入频率无影响）。
15. Sparkle 自动更新：未集成（避免无正式签名密钥时启用不安全更新源；见 RELEASE_CHECKLIST）。
16. 界面语言：当前 UI 为中文优先（模块含英文名与英文副标）；完整英文 String Catalog 本地化列入 backlog（设置页语言选项对系统语言敏感的字符串尚未全量接 Reactor）。
17. 应用图标为程序化生成的原创设计（渐变+磁贴+对勾）；正式品牌化设计可替换 AppResources/AppIcon.icns（构建脚本自动拾取）。

## 需人工验证清单（自动化无法覆盖）

- [ ] 命令面板 ⌃⇧Z 唤出/输入法候选/回车执行/Esc 关闭（真实键盘交互）
- [ ] 屏幕录制授权后的三种截图（区域/窗口/全屏）真实截屏效果
- [ ] 麦克风+语音识别授权后的真实转写准确率（中/英）
- [ ] 手机浏览器扫码上传/下载（真实局域网多设备）
- [ ] 拖拽文件到暂存架的触控板体验
- [ ] 深浅色切换、VoiceOver、多显示器、窗口缩放极限
- [ ] 应用签名后在其他 Mac 上的 Gatekeeper 首次启动体验（需 Developer ID 后验证）
