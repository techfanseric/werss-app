#!/bin/bash
# 公共函数库：所有 bin/ 与 batch/ 脚本 source 本文件。
# 约定：source 前 cd 到任意位置均可，路径全部由本文件推导。

# 应用根目录 = lib.sh 所在目录的上一级
WERSS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WERSS_ROOT

# 读取配置：先加载模板默认值，再用本机 config.env 覆盖（两处均用 ${VAR:-默认}，
# 因此环境变量临时覆盖依然生效；config.env 缺失时仅用模板也能跑）
set -a
. "$WERSS_ROOT/config.example.env"
[ -f "$WERSS_ROOT/config.env" ] && . "$WERSS_ROOT/config.env"
set +a

# PATH 补全：launchd 代理环境只有 /usr/bin:/bin:/usr/sbin:/sbin，
# 需补 docker(/usr/local/bin) 与 ego-browser(~/.local/bin)；Homebrew 路径一并补上
export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:$PATH"

BATCH="$WERSS_ROOT/batch"
LOGS="$WERSS_ROOT/logs"
CSV_PATH="${WERSS_CSV:-$WERSS_ROOT/companies.csv}"
mkdir -p "$LOGS"

log() { echo "$(date '+%m-%d %H:%M:%S') $*"; }

# 便携 timeout（macOS 无 GNU timeout，用 perl alarm 实现）：with_timeout <秒> <命令…>
with_timeout() {
  local secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# macOS 横幅通知（右上角，不抢焦点，约5秒收起进通知中心）：
#   notify "标题" "正文"
# 注：想横幅不自动收起，把 系统设置→通知→Script Editor 的样式设为「提醒」(Alerts) 即可
notify() {
  osascript -e "display notification \"${2:-}\" with title \"werss\" subtitle \"${1:-}\" sound name \"Glass\"" >/dev/null 2>&1 || true
}

# 需要人介入的提醒：响更明显的声音；**状态刚变为异常时**执行一次性动作（如打开扫码页），
# 之后每轮保活只发横幅不重复动作（横幅无按钮，也避免反复抢焦点）。
#   notify_important "状态键" "标题" "正文" ["一次性打开的URL"]
notify_important() {
  local key="$1" title="$2" body="$3" url="${4:-}"
  local f="$LOGS/.alert-state-$key" prev
  prev=$(cat "$f" 2>/dev/null || echo ok)
  osascript -e "display notification \"${body:-}\" with title \"werss 需要处理\" subtitle \"${title:-}\" sound name \"Sosumi\"" >/dev/null 2>&1 || true
  if [ "$prev" != "fail" ] && [ -n "$url" ]; then
    open "$url" 2>/dev/null
  fi
  echo fail > "$f"
}

# 异常恢复后清除状态（下次再出问题会重新触发一次性动作）
alert_clear() { rm -f "$LOGS/.alert-state-$1" 2>/dev/null; }

# 可点击行动的通知（首选）：terminal-notifier 发横幅，**点击横幅本体**执行命令
# （不自动打开浏览器，不打断当前操作）；未安装 terminal-notifier 时降级为
# notify_important（状态首变时自动打开一次 FALLBACK_URL）。
#   notify_action "状态键" "标题" "正文" "点击执行的命令" ["降级时打开的URL"]
notify_action() {
  local key="$1" title="$2" body="$3" cmd="$4" furl="${5:-}"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "werss 需要处理" -subtitle "$title" -message "$body" \
      -sound Sosumi -group "werss-$key" -execute "$cmd" >/dev/null 2>&1 \
      || notify "$title" "$body"
    mkdir -p "$LOGS"; echo fail > "$LOGS/.alert-state-$key"   # 记状态但从不自动打开
  else
    notify_important "$key" "$title" "$body" "$furl"
  fi
}

# 所有 docker 调用加超时：引擎半卡死时 CLI 可能无限挂起，不能拖死保活
docker_ok() { with_timeout 30 docker info >/dev/null 2>&1; }

app_alive() {
  curl -s -o /dev/null -m 5 -w '%{http_code}' "$WERSS_APP_URL/" 2>/dev/null | grep -q '^200$'
}

# 等应用 HTTP 200，最多 $1 秒（默认 300）
wait_app() {
  local deadline=$(( $(date +%s) + ${1:-300} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    app_alive && return 0
    sleep 10
  done
  return 1
}

container_up() {
  [ "$(with_timeout 30 docker ps --filter "name=^$WERSS_CONTAINER$" --format '{{.Names}}' 2>/dev/null)" = "$WERSS_CONTAINER" ]
}

runner_pid() { pgrep -f "bash .*run_forever.sh" | head -1; }
runner_alive() { pgrep -f "bash .*run_forever.sh" >/dev/null 2>&1; }

# 剩余待采集条数（slice1/2/3 总行数）
slice_remaining() {
  local n=0 f
  for f in "$BATCH"/slice[123].jsonl; do
    [ -f "$f" ] && n=$(( n + $(wc -l < "$f" | tr -d ' ') ))
  done
  echo "$n"
}

# 停 runner（含正在跑的 worker），用于导出/导入/停机
stop_runner() {
  pkill -f "bash .*run_forever.sh" 2>/dev/null
  pkill -f "python3 .*process_chunk.py" 2>/dev/null
  local i=0
  while (runner_alive || pgrep -f "python3 .*process_chunk.py" >/dev/null 2>&1) && [ $i -lt 30 ]; do
    sleep 2; i=$((i+1))
  done
  runner_alive && return 1 || return 0
}

# 拉起 runner（仅当还有剩余任务）
start_runner() {
  if runner_alive; then log "[runner] 已在运行 (pid $(runner_pid))"; return 0; fi
  if [ "$(slice_remaining)" -eq 0 ]; then log "[runner] 无剩余任务，不启动"; return 0; fi
  ( cd "$BATCH" && nohup bash run_forever.sh > runner.log 2>&1 < /dev/null & )
  sleep 3
  runner_alive && log "[runner] 已启动 (pid $(runner_pid))" || { log "[runner] 启动失败"; return 1; }
}

compose() {
  with_timeout 300 docker compose --env-file "$WERSS_ROOT/config.env" -f "$WERSS_ROOT/docker-compose.yml" "$@"
}

# Docker 守护进程保活：软恢复(open)无效说明引擎卡死，升级硬恢复(退出重开 Docker Desktop)。
# 今天实测引擎会半卡死（进程在、socket 无响应、docker info 挂起），只能退出重开救回。
ensure_docker() {
  docker_ok && return 0
  log "[docker] 守护进程未就绪，软恢复: open -a Docker…"
  open -a Docker 2>/dev/null
  local i=0
  until docker_ok || [ $i -ge 12 ]; do sleep 10; i=$((i+1)); done
  docker_ok && { log "[docker] 软恢复成功"; return 0; }
  log "[docker] 软恢复无效（引擎卡死），硬恢复: 退出并重开 Docker Desktop…"
  osascript -e 'quit app "Docker"' 2>/dev/null
  sleep 8
  i=0
  while pgrep -f com.docker.backend >/dev/null 2>&1 && [ $i -lt 24 ]; do sleep 5; i=$((i+1)); done
  pkill -f com.docker.backend 2>/dev/null; sleep 3
  open -a Docker 2>/dev/null
  i=0
  until docker_ok || [ $i -ge 30 ]; do sleep 10; i=$((i+1)); done
  docker_ok && { log "[docker] 硬恢复成功"; return 0; }
  return 1
}

# 统一启动：Docker → 容器 → 等健康 → runner
ensure_stack() {
  # 1. Docker 守护进程（软→硬恢复）
  if ! ensure_docker; then
    notify_important docker "Docker 未恢复" "Docker Desktop 软/硬恢复均失败，需人工检查"
    return 1
  fi
  # 2. 容器
  if ! container_up; then
    log "[容器] 未运行，compose up…"
    compose up -d || return 1
    log "[容器] 等待应用就绪（首次初始化约 2 分钟）…"
    wait_app 300 || { notify_important app "应用未就绪" "容器已启动但 5 分钟内 HTTP 未恢复，查看 docker logs $WERSS_CONTAINER"; return 1; }
  fi
  # 3. runner
  start_runner
}
