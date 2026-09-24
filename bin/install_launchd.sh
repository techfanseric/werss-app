#!/bin/bash
# 安装/刷新 launchd：① 30分钟保活+登录自启 ② 菜单栏应用常驻（崩溃自动重启）。幂等。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

mkdir -p "$HOME/Library/LaunchAgents" "$LOGS"

# 1. 保活
sed "s|__ROOT__|$WERSS_ROOT|g" "$WERSS_ROOT/launchd/com.werss.keepalive.plist.template" \
  > "$HOME/Library/LaunchAgents/com.werss.keepalive.plist"
launchctl unload "$HOME/Library/LaunchAgents/com.werss.keepalive.plist" >/dev/null 2>&1
launchctl load -w "$HOME/Library/LaunchAgents/com.werss.keepalive.plist" \
  && echo "launchd 保活已安装 ✓" || echo "launchd 保活安装失败"

# 2. 菜单栏应用
sed "s|__ROOT__|$WERSS_ROOT|g" "$WERSS_ROOT/launchd/com.werss.menubar.plist.template" \
  > "$HOME/Library/LaunchAgents/com.werss.menubar.plist"
launchctl unload "$HOME/Library/LaunchAgents/com.werss.menubar.plist" >/dev/null 2>&1
launchctl load -w "$HOME/Library/LaunchAgents/com.werss.menubar.plist" \
  && echo "launchd 菜单栏已安装 ✓" || echo "launchd 菜单栏安装失败"
