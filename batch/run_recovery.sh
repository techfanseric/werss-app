#!/bin/bash
# Ego Lite 真实浏览器逐篇恢复正文(支线工具,重构版:路径全部来自 lib.sh)
. "$(cd "$(dirname "$0")/.." && pwd)/bin/lib.sh"
cd "$BATCH"
W="$BATCH"
PENDING=$W/pending_articles.jsonl
DONE=$W/recovery_done.txt
RESULTS=$W/results
BATCH_SIZE=25
mkdir -p $RESULTS
touch $DONE

# 渲染 extract_one.js(注入本机绝对路径)
sed "s|__W__|$W|g" "$W/extract_one.js.template" > "$W/extract_one.gen.js"

# 剩余 = pending - 已完成
WERSS_BATCH_DIR=$W python3 - <<'PYEOF'
import json, os
W = os.environ["WERSS_BATCH_DIR"]
done_ids = set()
p = f"{W}/recovery_done.txt"
if os.path.exists(p):
    done_ids = {json.loads(l)["id"] for l in open(p, encoding="utf-8") if l.strip()}
items = [json.loads(l) for l in open(f"{W}/pending_articles.jsonl", encoding="utf-8") if l.strip()]
rest = [i for i in items if i["id"] not in done_ids]
with open(f"{W}/todo.jsonl", "w", encoding="utf-8") as f:
    for it in rest:
        f.write(json.dumps(it, ensure_ascii=False) + "\n")
print(f"剩余待恢复: {len(rest)}")
PYEOF

n=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "$line" > $W/current_item.json
  ID=$(echo "$line" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
  # Ego Lite 抽取(与其他 worker 用同一把目录锁串行)
  got=0
  while [ $got -eq 0 ]; do
    if mkdir $W/browser.lock.d 2>/dev/null; then got=1; else
      age=$(( $(date +%s) - $(stat -f %m $W/browser.lock.d 2>/dev/null || date +%s) ))
      [ $age -gt 600 ] && rm -rf $W/browser.lock.d
      sleep 2
    fi
  done
  EXTRACT=$(ego-browser nodejs < $W/extract_one.gen.js 2>&1 | grep -m1 "EXTRACTED" || true)
  rmdir $W/browser.lock.d 2>/dev/null
  if [[ "$EXTRACT" != EXTRACTED* ]]; then
    sleep 15
    while ! mkdir $W/browser.lock.d 2>/dev/null; do sleep 2; done
    EXTRACT=$(ego-browser nodejs < $W/extract_one.gen.js 2>&1 | grep -m1 "EXTRACTED" || echo "FAIL")
    rmdir $W/browser.lock.d 2>/dev/null
  fi
  if [[ "$EXTRACT" != EXTRACTED* ]]; then
    echo "$(date +%H:%M:%S) SKIP(extract失败) $ID | $EXTRACT"
    sleep 20
    continue
  fi
  cp $W/current_result.json $W/results/$ID.json
  echo "$line" >> $DONE
  n=$((n+1))
  echo "$(date +%H:%M:%S) [$n] 已抽取 $ID ($EXTRACT)"
  # 每 BATCH_SIZE 篇应用一次
  if [ $((n % BATCH_SIZE)) -eq 0 ]; then
    python3 - <<PYEOF
import json, glob
batch = [json.load(open(f, encoding="utf-8")) for f in glob.glob("$RESULTS/*.json")]
json.dump(batch, open("$W/batch.json", "w"), ensure_ascii=False)
PYEOF
    docker cp $W/batch.json "$WERSS_CONTAINER":/tmp/batch.json
    docker exec -w /app "$WERSS_CONTAINER" /app/env_x86_64/bin/python3 /tmp/apply_batch.py /tmp/batch.json
    rm -f $RESULTS/*.json
  fi
  sleep $((4 + RANDOM % 5))
done < $W/todo.jsonl
echo "RECOVERY_LOOP_DONE"
