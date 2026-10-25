# Deskvanic 功能矩阵

> 最后更新：2026-10-25（V1–V3 全量交付 + 独立审计修复后）。
> 全局：215 项自动化测试通过；六条端到端工作流 A–F 实测通过；独立审计 P0=0（P1/P2 已全部修复）。
> 状态取值：✅ 已实现并测试 / 🧪 已实现待人工验证 / 🚧 部分完成 / ⏸ 未开始。

## V1 六大模块

| 模块 | 目标功能 | 实现状态 | 代码位置 | 测试 | GUI 验证 |
|---|---|---|---|---|---|
| M01 Command Center | 全局快捷键/命令搜索/应用启动/授权文件搜索/资料检索/最近与收藏 | ✅ | `Sources/DeskvanicCommandCenter/` | 9 项 | 🧪 面板唤出需人工按键验证 |
| M02 ClipVault | 文本/URL/图片/文件历史、去重、固定收藏、纯文本粘贴、清理规则、暂停监控、排除应用、模板 | ✅ | `Sources/DeskvanicClipVault/` | 14 项 | 🧪 真实剪贴板流需人工复制验证 |
| M03 Capture Studio | 区域/窗口/全屏截图、OCR（中英）、条码、标注（裁剪/矩形/箭头/文字/真像素模糊）、固定悬浮、历史 | ✅ | `Sources/DeskvanicCapture/` | 13 项 | 🧪 屏幕录制权限需人工授权后验证 |
| M04 File Studio | 拖拽暂存、排序、图片转换/缩放/压缩/元数据剥离、批量重命名、PDF 合并/拆分/旋转/提取/优化、ZIP 打包/解压、队列、取消、模板 | ✅ | `Sources/DeskvanicFileStudio/` | 32 项 | 🧪 拖拽交互需人工验证 |
| M05 Recall Vault | 文本/链接/图片/PDF/文件收藏（复制与引用双模式）、标签、OCR、全文检索、筛选、列表/网格、预览、备份 | ✅ | `Sources/DeskvanicVault/` | 7 项 | 🧪 |
| M06 Text & Quick Tools | 文本清理/查找替换/大小写/行操作、Markdown 安全预览、对比、二维码、颜色、计算器、单位换算、计时器、番茄钟 | ✅ | `Sources/DeskvanicQuickTools/` | 31 项 | 🧪 |

## 核心服务层

| 能力 | 状态 | 测试 |
|---|---|---|
| SQLite（actor 封装、迁移、备份、完整性检查） | ✅ | 5 项 |
| FTS5 全文索引（CJK 分词、注入防护） | ✅ | 3 项 |
| 任务队列（并发上限、取消、进度、历史） | ✅ | 7 项 |
| 事件总线 | ✅ | 1 项 |
| 文件安全（路径包含/符号链接逃逸/原子写/SHA-256/废纸篓） | ✅ | 8 项 |
| 设置存储（防抖持久化、损坏回退） | ✅ | 2 项 |
| 权限中心（探测/请求/系统设置引导） | ✅ | 编译期验证 |
| 审计日志、书签存储、统一数据协议 | ✅ | 含于上述 |

## 已知限制（如实记录）

1. **剪贴板来源归属**：macOS 无公开 API 获取复制来源应用，采用前台应用启发式，仅供"排除应用"参考。
2. **JPEG 自动 EXIF**：ImageIO 为 JPEG 自动写入仅含创建时间的基础 EXIF；隐私剥离已验证 GPS/IPTC 清空，零 EXIF 需转 PNG。
3. **ZIP64 不支持**：单条目 >4GB 时明确报错。
4. **PDF 优化副作用**：页面转位图后文本不可选、注释书签丢失——UI 与文档均已明示。
5. **命令面板快捷键默认 ⌃⇧Z**：可在工具页自定义；与系统冲突时如实报告。
6. **GUI 深度验证**：自动化仅能验证进程存活、窗口存在、日志正常；交互流程需人工验证（见 `docs/TEST_REPORT.md` 中"待人工验证"清单）。

## V2 四模块

| 模块 | 实现状态 | 代码位置 | 测试 |
|---|---|---|---|
| M07 Clean Manager | ✅ | `Sources/DeskvanicClean/` | 9 项 |
| M08 NearLink | ✅ | `Sources/DeskvanicNearLink/` | 5 项（真实 curl 通信） |
| M09 SessionDock | ✅ | `Sources/DeskvanicSessionDock/` | 3 项 |
| M10 VoiceDock | ✅ | `Sources/DeskvanicVoice/` | 5 项 |

## V3 五模块

| 模块 | 实现状态 | 代码位置 | 测试 |
|---|---|---|---|
| M11 GuideCraft | ✅ | `Sources/DeskvanicGuide/` | 4 项 |
| M12 PaperTrail | ✅ | `Sources/DeskvanicPaper/` | 4 项 |
| M13 WebVault | ✅ | `Sources/DeskvanicWeb/` | 4 项 |
| M14 Media Studio | ✅ | `Sources/DeskvanicMedia/` | 3 项 |
| M15 Flow Engine | ✅ | `Sources/DeskvanicFlow/`（动作注册：宿主 FlowActions） | 15 项 |

## 端到端工作流 A–F

全部实测通过（`Tests/DeskvanicModuleTests/EndToEndTests.swift`）：A 截图→OCR→资料库→PDF；B 批量图→FlowEngine 缩放→压缩→NearLink 网络传输逐字节校验；C 下载目录整理（防重复触发+审计）；D 语音笔记（转写子步如实标注需授权）；E 凭证 OCR 预填→核实→到期→检索；F 教程→敏感扫描→HTML/PDF 导出。

## 独立审计

P0=0；P1×1、P2×9 全部修复（commit dc48db7）；遗留 P3×3 记录于 KNOWN_ISSUES。
