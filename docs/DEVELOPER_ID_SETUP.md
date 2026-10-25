# Apple Developer ID 设置指南（一次性，约 30 分钟人工操作）

> 这是全流程中**唯一无法代办**的环节（需你本人的 Apple ID、支付与法律协议）。
> 完成后，`scripts/sign-notarize.sh` 一条命令即可产出可对外分发的已签名公证包。

## 第 1 步：加入 Apple Developer Program（$99/年）

1. 打开 https://developer.apple.com/programs/enroll/
2. 用你的 Apple ID 登录（个人账号即可，无需公司主体）
3. 选择「个人 Individual」类型 → 填写信息 → 支付 $99
4. 等待激活（通常即时到 24 小时内）

## 第 2 步：创建 Developer ID Application 证书（2 分钟）

1. 打开 **Xcode → Settings（⌘,）→ Accounts** → 选中你的 Apple ID → 点 **Manage Certificates**
2. 左下角 **＋** → 选 **Developer ID Application**
3. 完成后证书自动进入钥匙串（本脚本会自动找到它）

## 第 3 步：存公证凭据（一次性，2 分钟）

公证需要你的 Apple ID + App 专用密码：

1. 打开 https://appleid.apple.com → 登录 → **登录与安全** → **App 专用密码** → 生成一个（命名如 "deskvanic-notary"），复制密码
2. 查你的 Team ID：https://developer.apple.com/account → Membership details → **Team ID**（10 位大写字母数字）
3. 终端执行（替换两处尖括号内容，密码提示时粘贴刚生成的 App 专用密码）：

```bash
xcrun notarytool store-credentials DESKVANIC_NOTARY --apple-id <你的AppleID> --team-id <你的TeamID>
```

## 第 4 步：一条命令签名+公证+打包

```bash
scripts/sign-notarize.sh
```

脚本自动完成：查找证书 → Hardened Runtime 签名（含 entitlements）→ 提交 Apple 公证并等待 → 装订票据 → Gatekeeper 复核 → 重新生成 `Deskvanic-0.1.0.zip` / `.dmg`。

之后其他 Mac 下载打开即无 Gatekeeper 警告（系统验证开发者身份与公证完整性）。

## 常见问题

- **不签名会怎样？** 本机正常用；发给别人的包首次打开需右键 → 打开（绕过警告），且 macOS 新版本可能直接拒绝。
- **App Store 上架？** 另需 App Store 分发证书与审核流程，与本脚本独立。
- **证书过期？** Developer ID 证书有效期约 5 年，到期在 Xcode 重新生成即可，已公证的旧包不受影响（公证记录在 Apple 服务器）。
