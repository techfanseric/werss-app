#!/bin/bash
# 一键启动全套：Docker → 容器 → 等健康 → 采集 runner（幂等，可重复执行）
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
ensure_stack && { log "[start] 全套已就绪"; } || { log "[start] 启动失败"; exit 1; }
