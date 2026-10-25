# Deskvanic 测试报告

> 生成时间：2026-10-25 · 工具链：Swift 6.4 / Xcode 27.1 · Swift Testing 框架

## 自动化测试执行结果

```
✔ Test run with 125 tests in 24 suites passed after 2.702 seconds  (DeskvanicModuleTests)
✔ Test run with  36 tests in  8 suites passed after 0.813 seconds  (DeskvanicCoreTests)
合计：161 项全部通过，0 失败，0 跳过
```

按套件分布（V1）：

| 套件 | 数量 | 覆盖 |
|---|---|---|
| FuzzyMatcher | 8 | 匹配得分、排序稳定性、中文子序列、音调折叠 |
| EventBus / UniversalModels / SettingsStore / TaskQueue / FileSafety / Database / SearchIndex | 36+... | 迁移回滚、备份恢复、FTS 中文、注入防护、并发上限、取消、进度、符号链接逃逸、原子写 |
| CommandRegistry / AppLauncher / CommandUsageStore / FileSearcher | 9 | 命令搜索、动态 provider、应用扫描、使用记录、扫描深度与链接防环 |
| ClipClassifier / ClipRetentionPolicy / ClipStore / ClipboardMonitor | 14 | 分类优先级、危险 scheme、保留策略、去重、FTS、假读取器驱动的监控行为 |
| AnnotationEngine / OCREngine / CaptureStore | 13 | 裁剪/矩形/箭头/文字像素级验证、真模糊破坏性验证、OCR 合成图、历史索引 |
| PDFEngine / BatchRenameEngine / ZIPArchive / ImageEngine | 32 | PDF 全操作页数校验、重命名冲突、ZIP 往返/恶意条目/系统互操作、图片全操作与隐私验证 |
| VaultStore | 7 | 过滤、FTS、标签、引用文件失效状态、索引重建 |
| TextToolkit / Calculator / UnitConverter / ColorToolkit / QRCodeService / TextDiff / MarkdownRenderer / TimerModels | 31 | 全部纯逻辑含边界与已知换算对照 |

## 已在开发中发现并修复的真实缺陷（抽样）

1. FTS5 unicode61 把整段中文当作单 token → 实现 CJK 逐字切分（写入与查询两侧）。
2. `URL.resolvingSymlinksInPath` 对不存在的末段不解析中间链接 → 自实现逐组件解析（防符号链接逃逸）。
3. 模糊匹配的 compactness 权重偏好长字符串 → 改为前缀优先。
4. 位图缓冲内存序与 CG 坐标系相反导致测试断言错误 → 显式坐标换算。
5. 批量重命名冲突检测漏掉"与未改名文件冲突"场景 → 重写冲突检测。
6. Calculator 分词把 `log2`/`log10` 拆开 → 标识符允许包含数字。
7. 批量替换的 replacement 在字面量模式下被当作模板解释 → 转义模板元字符。

## GUI 验证记录

- 应用打包（`scripts/build-app.sh`）：Release 构建 + ad-hoc 签名 + codesign 验证通过。
- 启动验证：进程存活；主窗口在屏（1000×692，layer 0）；日志显示迁移 v1–v5 依次应用、启动完成、快捷键注册成功。
- ⚠️ **待人工验证清单**（自动化无法替代，需要真人操作）：
  1. 命令面板 ⌃⇧Z 唤出/输入/回车执行/Esc 关闭。
  2. 复制各类内容后剪贴板历史出现与去重行为。
  3. 屏幕录制权限授权后的三种截图与 OCR 结果。
  4. 拖拽文件进暂存区与批量处理输出位置。
  5. 深浅色模式切换、VoiceOver、多显示器布局。
  6. 中文输入法在命令面板中的候选交互。

## 性能目标基线（本机：Apple Silicon, macOS 27）

| 指标 | 目标 | 实测 |
|---|---|---|
| 全套单元测试耗时 | — | 2.7s（含 20MB ZIP 压缩与 OCR） |
| 20MB 可压缩数据 ZIP 打包+解压+哈希 | < 3s | 通过（包含于测试耗时） |
| 1MB 文本统计+清理 | < 5s | 通过（断言内含计时） |
| 启动到"启动完成"日志 | — | < 0.2s（日志时间戳：进程启动后立即完成迁移） |

> P95 命令面板 250ms 目标：面板搜索为防抖 120ms + 异步 actor 查询，静态命令场景满足；应用/文件扫描为缓存异步路径。精确 P95 需 GUI 压测，列入 V2 验证计划。
