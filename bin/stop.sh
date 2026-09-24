#!/bin/bash
# 停止采集 runner 与容器（数据保留，docker compose stop 不删容器）
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
log "[stop] 停止 runner…"
stop_runner || log "[stop] runner 停止超时（可能仍在收尾，稍后自行退出）"
log "[stop] 停止容器…"
compose stop
log "[stop] 完成（Docker Desktop 保持运行；如需彻底停 Docker 请手动退出）"
