#!/bin/zsh
# 仅清理本项目构建产物与临时文件，不触碰系统或其他项目。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "==> 清理 SPM 构建目录"
rm -rf .build
echo "==> 清理打包产物"
rm -rf build dist
echo "==> 清理测试产物"
rm -rf TestResults
echo "✅ 完成"
