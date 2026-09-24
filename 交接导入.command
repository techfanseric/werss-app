#!/bin/bash
# 双击即从备份包恢复（换机交接：新机接收备份包后双击本文件）
cd "$(dirname "$0")"
echo "把备份包文件（werss-backup-*.tar.gz）拖入本窗口后回车；"
echo "若已放在本目录 backups/ 内，直接回车自动选最新的。"
read -p "> " DRAG
DRAG="${DRAG//\'/}"
exec bash bin/import.sh "${DRAG:-}"
