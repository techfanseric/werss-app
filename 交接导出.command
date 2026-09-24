#!/bin/bash
# 双击即导出交接备份包（采集暂停约 1-2 分钟，完成后自动恢复）
cd "$(dirname "$0")"
exec bash bin/export.sh
