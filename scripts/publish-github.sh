#!/bin/zsh
# 发布到 GitHub：替换 README 用户名占位符 → 创建/关联远端仓库 → 推送
# 用法：scripts/publish-github.sh <你的GitHub用户名> [仓库名，默认 Deskvanic]
# 前提（二选一）：
#   A. 已安装 gh 且 gh auth login 完成（推荐：脚本会用 gh 直接建仓库）
#   B. 已配置 SSH 公钥到 GitHub 账号，且你已在网页上建好空仓库
set -euo pipefail
# 注意：不能用 USERNAME 作变量名——zsh 中它是特殊系统参数，赋值无效
GH_USER="${1:?用法: scripts/publish-github.sh <GitHub用户名> [仓库名]}"
REPO="${2:-Deskvanic}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> 替换占位符 YOUR_USERNAME → $GH_USER"
grep -rl 'YOUR_USERNAME' README.md README.zh-CN.md >/dev/null 2>&1 && \
  sed -i '' "s/YOUR_USERNAME/$GH_USER/g" README.md README.zh-CN.md

git add -A && git commit -q -m "chore: 绑定 GitHub 仓库 $GH_USER/$REPO" || true

# 选择远端通道：gh 已登录 → gh 建仓库并推送；SSH 通 → SSH；否则 HTTPS
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "==> 检测到 gh 已登录，创建仓库并推送"
  git remote remove origin 2>/dev/null || true
  git branch -M main
  gh repo create "$GH_USER/$REPO" --public --source . --remote origin --push
elif ssh -T git@github.com >/dev/null 2>&1; then
  echo "==> 使用 SSH 通道推送（请确认已在网页创建空仓库 $GH_USER/$REPO）"
  git remote remove origin 2>/dev/null || true
  git remote add origin "git@github.com:$GH_USER/$REPO.git"
  git branch -M main
  git push -u origin main
else
  echo "==> 使用 HTTPS 通道推送（请确认已在网页创建空仓库 $GH_USER/$REPO）"
  git remote remove origin 2>/dev/null || true
  git remote add origin "https://github.com/$GH_USER/$REPO.git"
  git branch -M main
  git push -u origin main
fi

echo ""
echo "✅ 已推送。收尾（网页上点几下）："
echo "   1. https://github.com/$GH_USER/$REPO/actions 等 CI 变绿（徽章即亮）"
echo "   2. About 栏填简介 + Topics: macos swift swiftui native productivity open-source tools"
echo "   3. Releases → Draft new release → 标签 v0.1.0 → 上传 build/Deskvanic-0.1.0.dmg"
