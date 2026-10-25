# 品牌决策记录（BRAND.md）

## 商标检索结果（2026-10-25，发布前核查——任务书要求项）

**"OneDesk" 存在同行业在先商标，已决定弃用并改名。**

- 检索发现：**OneDesk™ 为 OneDesk Software Inc. 的注册商标**（onedesk.com），产品为"工单+项目管理"SaaS——与本应用同为软件产品，同名构成实际冲突风险。
- 检索过程：OneDesk（冲突）→ UniDeck（dashboard 平台，占用）→ ToolDeck（Android 应用+多个工具站，拥挤）→ Deskora（Windows 桌面整理器，占用）→ DeskForge（Steam 桌面管理器，占用）→ Deskvana（Slack 冥想应用）/Toolvana（肯尼亚工具店）→ **Deskvanic（零结果，干净）**。

## 新名称：**Deskvanic**

- 臆造词（fanciful mark）——商标保护最强类别；检索时点全网无同名软件。
- 品牌句保持：**Your Mac. One workspace.**
- 内部标识：bundle `com.deskvanic.app`、数据目录 `~/Library/Application Support/Deskvanic/`、Bonjour `_deskvanic._tcp`。

## 检索范围与法律边界（如实声明）

本检索为**网络级公开信息检索**（Google/Bing 可索引范围），不构成法律意见。正式发布前建议：
1. 在 [USPTO TESS](https://www.uspto.gov/trademarks/search)、[EUIPO](https://www.euipo.europa.eu/)、[中国商标网](https://sbj.cnipa.gov.cn/) 做官方数据库复核（类别 9/42 计算机软件）。
2. 如确认商业化，委托商标代理做全面清查与注册申请。

## 改名执行

- 全量改名由 `scripts/rename-product.sh` 完成（目录/文件/内容/bundle ID/数据路径一次性替换，215 项测试回归通过）。
- 以后如需再次改名：编辑 `.brand` 四行（旧名/新名/旧前缀/新前缀）→ 重跑脚本。
- 历史名称 "OneDesk" 仅存在于本地 git 存档分支（`history-archive`，未公开）、`.brand` 改名配置及相关文档说明中；公开仓库历史为单一干净提交，无旧商标代码残留。
