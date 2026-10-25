#!/bin/zsh
# 产品改名脚本：读取 .brand（当前名/当前小写名），追加或确认新名后全量替换。
# 用法：
#   1) 编辑 .brand 为四行：旧名 新名 旧bundle前缀 新bundle前缀
#   2) scripts/rename-product.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OLD_NAME=$(sed -n '1p' .brand)
NEW_NAME=$(sed -n '2p' .brand)
OLD_LOWER=$(sed -n '3p' .brand)
NEW_LOWER=$(sed -n '4p' .brand)

[[ -n "$OLD_NAME" && -n "$NEW_NAME" && "$OLD_NAME" != "$NEW_NAME" ]] || { echo "请先编辑 .brand（旧名/新名/bundle前缀）"; exit 1; }

echo "==> 改名: $OLD_NAME → $NEW_NAME (bundle: $OLD_LOWER → $NEW_LOWER)"

# 1. 目录重命名（含品牌前缀的模块目录）
for dir in Sources Tests; do
  find "$dir" -depth -type d -name "*$OLD_NAME*" | while read -r d; do
    nd="${d//$OLD_NAME/$NEW_NAME}"
    mv "$d" "$nd"
    echo "  目录: $d → $nd"
  done
done
# 2. 文件重命名
find Sources Tests Scripts scripts -type f -name "*$OLD_NAME*" 2>/dev/null | while read -r f; do
  nf="${f//$OLD_NAME/$NEW_NAME}"
  mv "$f" "$nf"
  echo "  文件: $f → $nf"
done
# 3. 内容替换（Swift/文档/配置/脚本）
find Sources Tests scripts AppResources docs README.md Package.swift .gitignore \
     -type f \( -name "*.swift" -o -name "*.md" -o -name "*.plist" -o -name "*.sh" -o -name "*.pbxproj" \) 2>/dev/null | while read -r f; do
  if grep -q "$OLD_NAME" "$f" 2>/dev/null; then
    sed -i '' "s/$OLD_NAME/$NEW_NAME/g; s/$OLD_LOWER/$NEW_LOWER/g" "$f"
    echo "  内容: $f"
  fi
done
# 4. 更新 .brand 标记
sed -i '' "1s/.*/$NEW_NAME/; 2s/.*/$NEW_LOWER/; 3s/.*/$NEW_LOWER/" .brand
echo "✅ 完成。全量回归：swift build && swift test"
