#!/bin/bash
# 直达扫码页：用 ego 浏览器自动登录并翻到微信读书扫码页，然后把 ego 窗口带到前台。
# 由「点击通知」触发（terminal-notifier -execute）；也可手动运行。
# ego 失败时兜底用默认浏览器打开（需手动登录，账密见通知/config.env）。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

GEN="$BATCH/open_scan.gen.js"
sed -e "s|__W__|$BATCH|g" -e "s|__APP_URL__|$WERSS_APP_URL|g" \
    -e "s|__ADMIN_USER__|$WERSS_ADMIN_USER|g" -e "s|__ADMIN_PASS__|$WERSS_ADMIN_PASS|g" \
    "$BATCH/open_scan.js.template" > "$GEN"

OUT=$(with_timeout 90 ego-browser nodejs < "$GEN" 2>&1 | tail -1)
rm -f "$GEN"
log "[open_scan] $OUT"

if echo "$OUT" | grep -q "SCAN_PAGE_READY"; then
  open -a "ego lite" 2>/dev/null   # 把扫码窗口带到前台
  notify "扫码页已打开" "请在 ego lite 窗口扫码"
  log "[open_scan] 扫码页已在前台"
else
  # 兜底：默认浏览器（无登录态会先到登录页，账密在通知正文里）
  open "$WERSS_APP_URL/weread" 2>/dev/null
  notify "请在浏览器登录后扫码" "登录账密：$WERSS_ADMIN_USER / $WERSS_ADMIN_PASS"
  log "[open_scan] ego 失败，已用默认浏览器兜底"
fi
