#!/bin/zsh
# Developer ID 签名 + 公证 + 装订 一条龙。
# 前置（一次性，约 30 分钟人工）：
#   1. 加入 Apple Developer Program（https://developer.apple.com/programs/ 用本人 Apple ID，$99/年）
#   2. Xcode → Settings → Accounts → 选中账号 → Manage Certificates → 左下 + →
#      "Developer ID Application"（自动生成证书进钥匙串）
#   3. 存公证凭据（一次性，替换 YOUR_APPLE_ID 与 TEAM_ID）：
#      xcrun notarytool store-credentials DESKVANIC_NOTARY --apple-id YOUR_APPLE_ID --team-id TEAM_ID
#      （密码处输入 Apple ID 的 App 专用密码：appleid.apple.com → 登录与安全 → App 专用密码生成）
# 之后每次发布只需：scripts/sign-notarize.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="build/Deskvanic.app"
PROFILE="DESKVANIC_NOTARY"

# 1. 查找 Developer ID 证书
IDENTITY=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')
if [[ -z "${IDENTITY:-}" ]]; then
  echo "❌ 未找到 Developer ID Application 证书。"
  echo "   请完成前置步骤 1-2（见脚本头部注释），然后重新运行本脚本。"
  security find-identity -v -p codesigning | head -5
  exit 1
fi
echo "==> 使用证书: $IDENTITY"

# 2. 签名（Hardened Runtime 必须——公证硬性要求）
echo "==> 签名（Developer ID + Hardened Runtime）"
codesign --force --options runtime --sign "$IDENTITY" \
  --entitlements AppResources/Deskvanic.entitlements \
  "$APP"
codesign --verify --deep --strict "$APP"

# 3. 公证
echo "==> 公证（Apple 服务器，通常 2-10 分钟）"
xcrun notarytool submit build/Deskvanic-0.1.0.zip \
  --keychain-profile "$PROFILE" --wait

# 4. 装订票据（离线验证）+ Gatekeeper 复核
echo "==> 装订票据"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute "$APP" && echo "✅ Gatekeeper 通过"

# 5. 重新生成已签名分发包
cd build
rm -f Deskvanic-0.1.0.zip Deskvanic-0.1.0.dmg
ditto -c -k --sequesterRsrc --keepParent Deskvanic.app Deskvanic-0.1.0.zip
hdiutil create -volname Deskvanic -srcfolder Deskvanic.app -ov -quiet Deskvanic-0.1.0.dmg
cd ..
echo "✅ 已签名+公证+装订完成：build/Deskvanic-0.1.0.zip / .dmg（可直接对外分发）"
