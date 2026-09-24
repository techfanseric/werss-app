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
EOF
  exit 0
fi

echo "$D $C $A $R | slice剩余$SLICE | CSV 已添加$CSV_ADDED/未找到$CSV_NOTFOUND/待处理$CSV_PENDING | 订阅$FEEDS 文章$ARTICLES 有正文$HAS_CONTENT"
[ "$WR" = "OK" ] && echo "weread授权:OK" || echo "weread授权:$WR(需扫码)"
