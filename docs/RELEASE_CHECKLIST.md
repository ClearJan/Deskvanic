# Deskvanic 发布清单（RELEASE_CHECKLIST.md）

> 模式：**完全开源（MIT）** —— 用户从源码构建，不需要 Developer ID 证书与公证。
> 状态：✅ 完成 / 📌 可选 / ❌ 未做（如实标注）

## 开源发布（已完成）

- ✅ LICENSE：MIT（`LICENSE`）
- ✅ README 面向开源重写（源码构建为主路径，安装包为辅 + Gatekeeper 绕过说明）
- ✅ 品牌核查并改名：OneDesk → **Deskvanic**（同行业在先商标冲突规避，详见 `docs/BRAND.md`；建议正式商业化前做官方数据库法律复核）
- ✅ 原创应用图标（程序化生成，替换 `AppResources/AppIcon.icns` 可品牌化）
- ✅ 零第三方依赖（供应链面为零）
- ✅ 隐私说明与安全审计公开（`docs/SECURITY_AUDIT.md`）

## 发布新版本（每次）

```bash
swift test                  # 215 项测试全绿
scripts/build-app.sh        # 构建 Deskvanic.app
cd build && ditto -c -k --sequesterRsrc --keepParent Deskvanic.app Deskvanic-<版本>.zip
# 或挂载验证后：hdiutil create -volname Deskvanic -srcfolder Deskvanic.app -ov Deskvanic-<版本>.dmg
git tag v<版本> && git push --tags   # 推送到公开仓库后
```

## 📌 可选项（如果你将来改变主意）

- **Developer ID 签名+公证**（$99/年）：消除下载者的 Gatekeeper 提示。全部自动化已就绪：
  `scripts/sign-notarize.sh`（前置步骤见 `docs/DEVELOPER_ID_SETUP.md`）
- **Sparkle 自动更新**：签名落地后再评估
- **上架 Mac App Store**：另需审核流程

## 回归验证（发布前每次必跑）

```bash
swift test
scripts/build-app.sh
open build/Deskvanic.app
```
