#!/bin/bash
# 重建 WERSS菜单栏.app（改 src/menubar_app.swift / src/review_ui.swift 后运行；新机无需，仓库带已编译二进制）
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/WERSS菜单栏.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/main" "$ROOT/src/menubar_app.swift" "$ROOT/src/review_ui.swift"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 && echo "构建+签名 ✓ ($APP)"
