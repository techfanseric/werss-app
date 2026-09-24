#!/bin/bash
# 卸载 launchd 保活（回退用，不影响数据）
PLIST_DST="$HOME/Library/LaunchAgents/com.werss.keepalive.plist"
launchctl unload "$PLIST_DST" >/dev/null 2>&1
rm -f "$PLIST_DST"
echo "launchd 保活已卸载（$PLIST_DST）"
