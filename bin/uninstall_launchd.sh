#!/bin/bash
# 卸载 launchd（保活 + 菜单栏），回退用，不影响数据
for PLIST in com.werss.keepalive com.werss.menubar; do
  launchctl unload "$HOME/Library/LaunchAgents/$PLIST.plist" >/dev/null 2>&1
  rm -f "$HOME/Library/LaunchAgents/$PLIST.plist"
  echo "已卸载 $PLIST"
done
