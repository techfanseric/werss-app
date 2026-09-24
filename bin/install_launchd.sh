#!/bin/bash
# 安装/刷新 launchd 保活（登录自启 + 每 30 分钟保活），幂等。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PLIST_SRC="$WERSS_ROOT/launchd/com.werss.keepalive.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/com.werss.keepalive.plist"

mkdir -p "$HOME/Library/LaunchAgents" "$LOGS"
sed "s|__ROOT__|$WERSS_ROOT|g" "$PLIST_SRC" > "$PLIST_DST"

launchctl unload "$PLIST_DST" >/dev/null 2>&1
launchctl load -w "$PLIST_DST" && echo "launchd 保活已安装 ✓（$PLIST_DST）" || { echo "launchd 安装失败"; exit 1; }
