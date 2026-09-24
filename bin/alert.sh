#!/bin/bash
# 持久系统提醒：display alert 模态框，不自动消失，直到用户点按钮。
# 由 lib.sh 的 alert_notify() 以分离进程调用（不阻塞调用方）。
# 用法: alert.sh "标题" "正文" ["动作按钮文字"] ["动作URL"]
#   传了按钮+URL 时，用户点动作按钮会打开 URL；点「知道了」仅关闭。
TITLE="$1"; BODY="$2"; BTN="${3:-}"; URL="${4:-}"

afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &

R=$(osascript - "$TITLE" "$BODY" "$BTN" <<'APPLESCRIPT' 2>/dev/null
on run argv
  set t to item 1 of argv
  set b to item 2 of argv
  set btn to item 3 of argv
  if btn is "" then
    display alert t message b buttons {"知道了"} default button "知道了" as informational
    return ""
  else
    set r to display alert t message b buttons {"知道了", btn} default button btn as informational
    return button returned of r
  end if
end run
APPLESCRIPT
)

if [ -n "$R" ] && [ "$R" = "$BTN" ] && [ -n "$URL" ]; then
  open "$URL"
fi
