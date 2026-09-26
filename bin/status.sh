#!/bin/bash
# 状态报告。默认人类可读多行；--parse 输出机器可读 key=value（菜单栏应用用）。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

MODE="${1:-}"   # 先存：后面 set -- 会覆盖位置参数

docker_ok && D=OK || D=DOWN
container_up && C=UP || C=DOWN
app_alive && A=OK || A=DOWN
runner_alive && R="UP" || R="DOWN"

# CSV 进度
CSV_ADDED=0; CSV_NOTFOUND=0; CSV_PENDING=0
if [ -f "$CSV_PATH" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      CSV_ADDED) CSV_ADDED="$v" ;;
      CSV_NOTFOUND) CSV_NOTFOUND="$v" ;;
      CSV_PENDING) CSV_PENDING="$v" ;;
    esac
  done < <(python3 - "$CSV_PATH" <<'PY'
import csv, sys, collections
rows = list(csv.reader(open(sys.argv[1], newline="", encoding="utf-8-sig")))
h = rows[0]; i = h.index("wx_mp_status")
c = collections.Counter(r[i] for r in rows[1:] if r and len(r) > i)
print("CSV_ADDED=%d" % c.get('已添加', 0))
print("CSV_NOTFOUND=%d" % c.get('未找到', 0))
print("CSV_PENDING=%d" % c.get('待处理', 0))
PY
)
fi
SLICE=$(slice_remaining)

# 文章/订阅数（容器内 SQLite 只读查询，带超时防引擎卡死拖住菜单栏）
FEEDS=-1; ARTICLES=-1; HAS_CONTENT=-1
if container_up; then
  OUT=$(with_timeout 15 docker exec "$WERSS_CONTAINER" python3 -c "
import sqlite3
db = sqlite3.connect('file:/app/data/db.db?mode=ro', uri=True)
print(db.execute('select count(*) from feeds').fetchone()[0],
      db.execute('select count(*) from articles').fetchone()[0],
      db.execute('select count(*) from articles where has_content=1').fetchone()[0])
" 2>/dev/null) && { set -- $OUT; FEEDS=$1; ARTICLES=$2; HAS_CONTENT=$3; }
fi

# ego 浏览器（CLI 存在 + 应用进程存活）
if [ -x "$HOME/.local/bin/ego-browser" ] && pgrep -f "ego lite.app/Contents" >/dev/null 2>&1; then E=OK; else E=DOWN; fi

# 磁盘可用（根卷 GB）与最近备份天数
DISK_GB=$(df -g / 2>/dev/null | awk 'NR==2{print $4}')
BK_DAYS=-1
NEWEST=$(ls -t "$WERSS_ROOT"/backups/werss-backup-*.tar.gz 2>/dev/null | head -1)
[ -n "$NEWEST" ] && BK_DAYS=$(( ( $(date +%s) - $(stat -f %m "$NEWEST") ) / 86400 ))

# 限流冷却（最近 1 小时 runner.log 有 search_throttled）
TH=no
if [ -f "$BATCH/runner.log" ]; then
  TH=$(python3 - "$BATCH/runner.log" <<'ENDPY'
import sys, re, datetime
now = datetime.datetime.now()
last = None
for line in open(sys.argv[1], encoding='utf-8', errors='ignore'):
    if 'search_throttled' in line:
        m = re.match(r'(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)', line)
        if m:
            try:
                t = datetime.datetime(now.year, int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)))
                if t > now: t = t.replace(year=now.year - 1)
                last = max(last, t) if last else t
            except Exception:
                pass
print('yes' if last and (now - last).total_seconds() < 3600 else 'no')
ENDPY
)
fi

# weread 授权
WR=UNKNOWN
if app_alive; then
  TOK=$(curl -s -m 10 -X POST "$WERSS_APP_URL/api/v1/wx/auth/login" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "username=$WERSS_ADMIN_USER" \
      --data-urlencode "password=$WERSS_ADMIN_PASS" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('access_token',''))" 2>/dev/null)
  if [ -n "$TOK" ]; then
    RESP=$(curl -s -m 10 -X POST "$WERSS_APP_URL/api/v1/wx/weread/test" -H "Authorization: Bearer $TOK" 2>/dev/null)
    echo "$RESP" | grep -qiE 'true|有效|success|"code":200' && WR=OK || WR=FAIL
  else
    WR=LOGINERR
  fi
fi

# 跟踪扫码时刻：仅在授权真正失效(FAIL/LOGINERR)后恢复(OK)时写入，即"刚扫码"；
# UNKNOWN→OK（应用/容器重启但授权本来就有效）不算扫码，不刷新时间
WR_STATE_FILE="$LOGS/.weread_state"
WR_OK_AT_FILE="$LOGS/.weread_ok_at"
PREV_WR=$(cat "$WR_STATE_FILE" 2>/dev/null || echo "UNKNOWN")
if [ "$WR" = "OK" ] && { [ "$PREV_WR" = "FAIL" ] || [ "$PREV_WR" = "LOGINERR" ]; }; then
  date +%s > "$WR_OK_AT_FILE"   # 仅失效→恢复（=扫码）时记录
fi
echo "$WR" > "$WR_STATE_FILE"
WR_OK_AT=$(cat "$WR_OK_AT_FILE" 2>/dev/null || echo "-1")

if [ "$MODE" = "--parse" ]; then
  cat <<EOF
docker=$D
container=$C
app=$A
runner=$R
slice=$SLICE
csv_added=$CSV_ADDED
csv_notfound=$CSV_NOTFOUND
csv_pending=$CSV_PENDING
feeds=$FEEDS
articles=$ARTICLES
has_content=$HAS_CONTENT
weread=$WR
weread_ok_at=$WR_OK_AT
ego=$E
disk_gb=$DISK_GB
backup_days=$BK_DAYS
throttled=$TH
EOF
  exit 0
fi

echo "$D $C $A $R | slice剩余$SLICE | CSV 已添加$CSV_ADDED/未找到$CSV_NOTFOUND/待处理$CSV_PENDING | 订阅$FEEDS 文章$ARTICLES 有正文$HAS_CONTENT"
[ "$WR" = "OK" ] && echo "weread授权:OK" || echo "weread授权:$WR(需扫码)"
echo "ego:$E 磁盘可用:${DISK_GB}G 最近备份:${BK_DAYS}天前 限流:$TH"
