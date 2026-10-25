import DeskvanicCapture
import DeskvanicClipVault
import DeskvanicCommandCenter
import DeskvanicClean
import DeskvanicFlow
import DeskvanicGuide
import DeskvanicMedia
import DeskvanicPaper
import DeskvanicWeb
import DeskvanicNearLink
import DeskvanicSessionDock
import DeskvanicVoice
import DeskvanicCore
import DeskvanicFileStudio
import DeskvanicQuickTools
import DeskvanicVault
import DeskvanicUIShared
import SwiftUI

/// 各功能模块的工具适配器：把模块入口注册进 ToolRegistry。
/// 模块自身不依赖 UIShared，由宿主完成桥接。

struct CommandCenterTool: ToolModule {
    let id = "command-center"
    let name = "全局命令中心"
    let nameEn = "Command Center"
    let icon = "command.square"
    let summary = "全局快捷键唤出，快速查找并执行命令、应用、文件与资料"
    let section = ToolSection.essentials

    @MainActor
    func makeView() -> AnyView {
        AnyView(CommandCenterToolView())
    }
}

struct ClipVaultTool: ToolModule {
    let id = "clip-vault"
    let name = "剪贴板"
    let nameEn = "ClipVault"
    let icon = "doc.on.clipboard"
    let summary = "剪贴板历史、搜索、固定收藏、纯文本粘贴与快捷模板"
    let section = ToolSection.essentials

    @MainActor
    func makeView() -> AnyView {
        AnyView(ClipVaultToolView())
    }
}

struct CaptureTool: ToolModule {
    let id = "capture-studio"
    let name = "截图与识别"
    let nameEn = "Capture Studio"
    let icon = "camera.viewfinder"
    let summary = "区域/窗口/全屏截图、本机 OCR、条码识别、标注与固定悬浮"
    let section = ToolSection.essentials

    @MainActor
    func makeView() -> AnyView {
        AnyView(CaptureToolView())
    }
}

struct VaultTool: ToolModule {
    let id = "recall-vault"
    let name = "资料检索中心"
    let nameEn = "Recall Vault"
    let icon = "archivebox"
    let summary = "保存文本、链接、图片与 PDF，标签组织与全文检索"
    let section = ToolSection.files

    @MainActor
    func makeView() -> AnyView {
        AnyView(VaultToolView())
    }
}

struct FileStudioTool: ToolModule {
    let id = "file-studio"
    let name = "文件处理中心"
    let nameEn = "File Studio"
    let icon = "wand.and.rays"
    let summary = "拖拽暂存、PDF 合并拆分旋转提取优化、批量重命名、任务队列"
    let section = ToolSection.files

    @MainActor
    func makeView() -> AnyView {
        AnyView(FileStudioView())
    }
}

struct QuickToolsEntry: ToolModule {
    let id = "quick-tools"
    let name = "文字与快捷工具"
    let nameEn = "Text & Quick Tools"
    let icon = "textformat.123"
    let summary = "文本清理替换、Markdown、对比、二维码、颜色、计算器、单位、计时器"
    let section = ToolSection.essentials

    @MainActor
    func makeView() -> AnyView {
        AnyView(QuickToolsView())
    }
}

struct CleanTool: ToolModule {
    let id = "clean-manager"
    let name = "整理与磁盘空间"
    let nameEn = "Clean Manager"
    let icon = "trash.slash"
    let summary = "授权目录扫描、大文件统计、完全重复与相似图片、自动整理（可恢复）"
    let section = ToolSection.files

    @MainActor
    func makeView() -> AnyView {
        AnyView(CleanToolView())
    }
}

struct NearLinkTool: ToolModule {
    let id = "nearlink"
    let name = "跨设备互传"
    let nameEn = "NearLink"
    let icon = "arrow.left.arrow.right.circle"
    let summary = "局域网 + 访问令牌，手机浏览器扫码互传文件与文本"
    let section = ToolSection.system

    @MainActor
    func makeView() -> AnyView {
        AnyView(NearLinkToolView())
    }
}

struct VoiceTool: ToolModule {
    let id = "voice-dock"
    let name = "语音输入"
    let nameEn = "VoiceDock"
    let icon = "mic"
    let summary = "录音转写（优先设备端）、音频导入、用户词典、插入到前台应用"
    let section = ToolSection.system

    @MainActor
    func makeView() -> AnyView {
        AnyView(VoiceDockView())
    }
}

struct SessionDockTool: ToolModule {
    let id = "session-dock"
    let name = "桌面工作空间"
    let nameEn = "SessionDock"
    let icon = "rectangle.split.2x1"
    let summary = "保存/恢复窗口布局，一键启动一组应用与网页"
    let section = ToolSection.system

    @MainActor
    func makeView() -> AnyView {
        AnyView(SessionDockView())
    }
}

struct FlowTool: ToolModule {
    let id = "flow-engine"
    let name = "自动化工作流"
    let nameEn = "Flow Engine"
    let icon = "flowchart"
    let summary = "动作节点串联、类型检查、模拟运行、文件夹事件触发"
    let section = ToolSection.advanced

    @MainActor
    func makeView() -> AnyView {
        AnyView(FlowView())
    }
}

struct MediaTool: ToolModule {
    let id = "media-studio"
    let name = "媒体处理"
    let nameEn = "Media Studio"
    let icon = "waveform"
    let summary = "音视频裁剪、音频提取、格式转换、GIF 生成（输出校验）"
    let section = ToolSection.advanced

    @MainActor
    func makeView() -> AnyView {
        AnyView(MediaStudioView())
    }
}

struct GuideTool: ToolModule {
    let id = "guide-craft"
    let name = "操作教程生成"
    let nameEn = "GuideCraft"
    let icon = "doc.text.below.ecg"
    let summary = "截图步骤、编号标注、说明编辑、敏感信息检查、导出 MD/HTML/PDF"
    let section = ToolSection.advanced

    @MainActor
    func makeView() -> AnyView {
        AnyView(GuideCraftView())
    }
}

struct PaperTool: ToolModule {
    let id = "paper-trail"
    let name = "生活文件管家"
    let nameEn = "PaperTrail"
    let icon = "receipt"
    let summary = "凭证导入、OCR 字段预填+人工核实、到期提醒、全文检索"
    let section = ToolSection.advanced

    @MainActor
    func makeView() -> AnyView {
        AnyView(PaperTrailView())
    }
}

struct WebVaultTool: ToolModule {
    let id = "web-vault"
    let name = "网页资料库"
    let nameEn = "Web Vault"
    let icon = "globe"
    let summary = "链接收藏、元数据抓取、正文提取、去重、阅读清单"
    let section = ToolSection.advanced

    @MainActor
    func makeView() -> AnyView {
        AnyView(WebVaultView())
    }
}
