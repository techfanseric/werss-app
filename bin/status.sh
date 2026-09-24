#!/bin/bash
# 一行/数行状态报告：Docker、容器、应用、runner、进度、文章数、授权状态
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

docker_ok && D=docker:OK || D=docker:DOWN
container_up && C=container:UP || C=container:DOWN
app_alive && A=app:OK || A=app:DOWN
runner_alive && R="runner:UP(pid $(runner_pid))" || R=runner:DOWN

# CSV 进度
CSVSTAT=""
if [ -f "$CSV_PATH" ]; then
  CSVSTAT=$(python3 - "$CSV_PATH" <<'PY'
import csv, sys, collections
rows = list(csv.reader(open(sys.argv[1], newline="", encoding="utf-8-sig")))
h = rows[0]; i = h.index("wx_mp_status")
c = collections.Counter(r[i] for r in rows[1:] if r and len(r) > i)
print(f"CSV 已添加{c.get('已添加',0)}/未找到{c.get('未找到',0)}/待处理{c.get('待处理',0)}/待复核{c.get('待复核',0)}")
PY
)
fi

# 文章/订阅数（容器内 SQLite 只读查询）
DBSTAT=""
if container_up; then
  DBSTAT=$(docker exec "$WERSS_CONTAINER" python3 -c "
import sqlite3
db = sqlite3.connect('file:/app/data/db.db?mode=ro', uri=True)
f = db.execute('select count(*) from feeds').fetchone()[0]
a = db.execute('select count(*) from articles').fetchone()[0]
hc = db.execute('select count(*) from articles where has_content=1').fetchone()[0]
print(f'订阅{f} 文章{a} 有正文{hc}')
" 2>/dev/null) || DBSTAT="db:查询失败"
fi

echo "$D $C $A $R | slice剩余$(slice_remaining) | $CSVSTAT | $DBSTAT"

# 授权状态（可选检查，登录失败不影响状态行）
if app_alive && [ -n "$WERSS_ADMIN_USER" ]; then
  TOK=$(curl -s -m 10 -X POST "$WERSS_APP_URL/api/v1/wx/auth/login" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "username=$WERSS_ADMIN_USER" \
      --data-urlencode "password=$WERSS_ADMIN_PASS" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('access_token',''))" 2>/dev/null)
  if [ -n "$TOK" ]; then
    WR=$(curl -s -m 10 -X POST "$WERSS_APP_URL/api/v1/wx/weread/test" -H "Authorization: Bearer $TOK" 2>/dev/null | head -c 200)
    echo "$WR" | grep -qiE 'true|有效|success|200' && echo "weread授权:OK" || echo "weread授权:疑似失效(需扫码)  resp=${WR:0:80}"
  else
    echo "管理端登录:失败(检查 config.env 凭据)"
  fi
fi
