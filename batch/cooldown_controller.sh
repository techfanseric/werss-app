#!/bin/bash
# 冷静期控制器:等到冷静期结束 → 金丝雀探测 → 通过则启动 runner(低速档)
# 用法: nohup bash cooldown_controller.sh "YYYY-MM-DD HH:MM" > cooldown_controller.log 2>&1 &
#   第1参数 = 冷却截止时间;省略则立即进入探测阶段。
. "$(cd "$(dirname "$0")/.." && pwd)/bin/lib.sh"
cd "$BATCH"

if [ -n "${1:-}" ]; then
  DEADLINE=$(date -j -f "%Y-%m-%d %H:%M" "$1" +%s) || { echo "用法: $0 \"YYYY-MM-DD HH:MM\""; exit 1; }
else
  DEADLINE=$(date +%s)
fi

log() { echo "$(date '+%m-%d %H:%M:%S') $*"; }

log "冷静期控制器启动,截止 $(date -r $DEADLINE '+%m-%d %H:%M')"

# 阶段1: 等到截止时间
while [ $(date +%s) -lt $DEADLINE ]; do
  REMAIN=$(( (DEADLINE - $(date +%s)) / 60 ))
  log "冷却中,剩余 ${REMAIN} 分钟"
  sleep 570
done

# 阶段2: 截止后,每小时探测一次,最多12小时
ATTEMPT=0
while [ $ATTEMPT -lt 12 ]; do
  ATTEMPT=$((ATTEMPT+1))
  log "第 $ATTEMPT 次金丝雀探测"
  RES=$(python3 canary.py 2>&1 | tail -1)
  log "  $RES"
  if echo "$RES" | grep -q "found=0"; then
    log "仍被限流,1小时后再探测"
    sleep 3600
  else
    log "搜索已解封!启动 runner"
    nohup bash run_forever.sh > runner.log 2>&1 &
    log "runner 已启动(进程 $!)"
    notify "限流已解除" "runner 重新启动"
    exit 0
  fi
done

log "12小时内搜索未解封,需要人工介入。退出。"
notify "限流未解除" "冷静期控制器 12 小时探测未解封，需人工介入"
