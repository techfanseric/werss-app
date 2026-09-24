#!/bin/bash
# 30 分钟保活：Docker → 容器 → runner → 快检 → 需要人时发 macOS 系统通知。
# 由 launchd（com.werss.keepalive）每 30 分钟调用，也可手动执行。带并发锁。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

LOCK="$WERSS_ROOT/.keepalive.lock.d"
if ! mkdir "$LOCK" 2>/dev/null; then
  # 已有实例在跑；超过 40 分钟视为残留
  if [ $(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || date +%s) )) -gt 2400 ]; then
    rmdir "$LOCK" 2>/dev/null
  else
    echo "$(date '+%m-%d %H:%M:%S') [keepalive] 上一轮仍在进行，跳过"
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

STATE="$LOGS/keepalive_fails"
FAILS=$(cat "$STATE" 2>/dev/null || echo 0)
ok=1

# ---- 1. Docker 守护进程 ----
if ! docker_ok; then
  log "[keepalive] Docker 守护进程未就绪，启动 Docker Desktop…"
  open -a Docker 2>/dev/null
  i=0; until docker_ok || [ $i -ge 20 ]; do sleep 15; i=$((i+1)); done
  if docker_ok; then
    log "[keepalive] Docker 已恢复"
  else
    notify "werss 保活失败" "Docker Desktop 5 分钟未恢复，需人工检查"
    echo $(( FAILS + 1 )) > "$STATE"; exit 1
  fi
fi

# ---- 2. 容器 ----
if ! container_up; then
  log "[keepalive] 容器未运行，拉起…"
  compose up -d
  log "[keepalive] 等待应用 HTTP 就绪（初始化约 2 分钟）…"
  if wait_app 300; then
    log "[keepalive] 容器已恢复"
  else
    notify "werss 保活失败" "容器已启动但应用 5 分钟未就绪，请看 docker logs $WERSS_CONTAINER"
    docker logs --tail 30 "$WERSS_CONTAINER" >> "$LOGS/keepalive.log" 2>&1
    echo $(( FAILS + 1 )) > "$STATE"; exit 1
  fi
fi

# ---- 3. 采集 runner ----
if runner_alive; then
  :
elif [ "$(slice_remaining)" -gt 0 ]; then
  log "[keepalive] runner 未运行且还有 $(slice_remaining) 条任务，拉起…"
  start_runner
  sleep 60
  if ! runner_alive; then
    notify "werss 保活" "runner 拉起失败，请查看 $BATCH/runner.log"
    ok=0
  fi
else
  log "[keepalive] 无剩余任务，runner 保持停止"
fi

# ---- 4. 快检：weread 授权 ----
alert_weread() {
  notify "需要扫码：微信读书授权失效" "文章正文采集已暂停，请扫码恢复；二维码已保存/页面已打开"
  sed -e "s|__W__|$BATCH|g" -e "s|__APP_URL__|$WERSS_APP_URL|g" \
      -e "s|__ADMIN_USER__|$WERSS_ADMIN_USER|g" -e "s|__ADMIN_PASS__|$WERSS_ADMIN_PASS|g" \
      "$BATCH/login_alert.js.template" > "$BATCH/login_alert.gen.js"
  with_timeout 90 ego-browser nodejs < "$BATCH/login_alert.gen.js" >/dev/null 2>&1
  open "$WERSS_APP_URL/weread" 2>/dev/null
}

if app_alive; then
  TOK=$(curl -s -m 10 -X POST "$WERSS_APP_URL/api/v1/wx/auth/login" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "username=$WERSS_ADMIN_USER" \
      --data-urlencode "password=$WERSS_ADMIN_PASS" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('access_token',''))" 2>/dev/null)
  if [ -n "$TOK" ]; then
    WR=$(curl -s -m 10 -X POST "$WERSS_APP_URL/api/v1/wx/weread/test" -H "Authorization: Bearer $TOK" 2>/dev/null)
    if ! echo "$WR" | grep -qiE 'true|有效|success|"code":200'; then
      log "[keepalive] weread 授权疑似失效，触发扫码提醒"
      alert_weread
    fi
  else
    log "[keepalive] 管理端登录失败（检查 config.env 凭据）"
  fi
else
  log "[keepalive] 应用未响应（容器标记 Up 但 HTTP 不通）"
  ok=0
fi

# ---- 5. 汇总 ----
if [ $ok -eq 1 ]; then
  echo 0 > "$STATE"
  echo "$(date '+%m-%d %H:%M:%S') [keepalive] 正常 docker:OK 容器:UP app:OK runner:$(runner_alive && echo UP || echo 停) slice剩余:$(slice_remaining)"
else
  FAILS=$(( FAILS + 1 )); echo "$FAILS" > "$STATE"
  if [ "$FAILS" -ge 3 ]; then
    notify "werss 连续 ${FAILS} 次异常" "自动恢复失败，需要人工介入（详见 logs/keepalive 相关日志）"
  fi
  exit 1
fi
