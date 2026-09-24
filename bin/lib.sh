#!/bin/bash
# 公共函数库：所有 bin/ 与 batch/ 脚本 source 本文件。
# 约定：source 前 cd 到任意位置均可，路径全部由本文件推导。

# 应用根目录 = lib.sh 所在目录的上一级
WERSS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WERSS_ROOT

# 读取配置（不覆盖已导出的值，便于演练时用环境变量临时覆盖容器名等）
set -a
. "$WERSS_ROOT/config.env"
set +a

# ego-browser CLI 注册在 ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"

BATCH="$WERSS_ROOT/batch"
LOGS="$WERSS_ROOT/logs"
CSV_PATH="${WERSS_CSV:-$WERSS_ROOT/companies.csv}"
mkdir -p "$LOGS"

log() { echo "$(date '+%m-%d %H:%M:%S') $*"; }

# macOS 系统通知：notify "标题" "正文"
notify() {
  osascript -e "display notification \"${2:-}\" with title \"werss\" subtitle \"${1:-}\" sound name \"Glass\"" >/dev/null 2>&1 || true
}

docker_ok() { docker info >/dev/null 2>&1; }

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
  [ "$(docker ps --filter "name=^$WERSS_CONTAINER$" --format '{{.Names}}' 2>/dev/null)" = "$WERSS_CONTAINER" ]
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
  ( cd "$BATCH" && nohup bash run_forever.sh > runner.log 2>&1 & )
  sleep 3
  runner_alive && log "[runner] 已启动 (pid $(runner_pid))" || { log "[runner] 启动失败"; return 1; }
}

compose() {
  docker compose --env-file "$WERSS_ROOT/config.env" -f "$WERSS_ROOT/docker-compose.yml" "$@"
}

# 统一启动：Docker → 容器 → 等健康 → runner
ensure_stack() {
  # 1. Docker 守护进程
  if ! docker_ok; then
    log "[docker] 守护进程未就绪，启动 Docker Desktop…"
    open -a Docker 2>/dev/null || { notify "启动失败" "未找到 Docker Desktop，请先运行 安装.command"; return 1; }
    local i=0
    until docker_ok || [ $i -ge 20 ]; do sleep 15; i=$((i+1)); done
    docker_ok || { notify "Docker 未恢复" "等待 5 分钟仍未就绪，需人工检查"; return 1; }
  fi
  # 2. 容器
  if ! container_up; then
    log "[容器] 未运行，compose up…"
    compose up -d || return 1
    log "[容器] 等待应用就绪（首次初始化约 2 分钟）…"
    wait_app 300 || { notify "应用未就绪" "容器已启动但 5 分钟内 HTTP 未恢复，查看 docker logs $WERSS_CONTAINER"; return 1; }
  fi
  # 3. runner
  start_runner
}
