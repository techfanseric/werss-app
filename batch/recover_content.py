#!/usr/bin/env python3
"""存量文章正文补齐:通过微信读书 content 接口逐篇补(不依赖已过期的临时链接)。

用法: python3 recover_content.py [本批数量] [起始间隔秒]
自适应节奏:成功则缓慢提速,失败按 1.7 倍退避(上限 240 秒)。
"""
import sys, time, sqlite3, datetime

sys.path.insert(0, "/app")
import init_sys as init
init.init()  # 加载许可文件/加密配置(含微信读书Cookie)
from core.config import cfg
from core.wx.model.weread_mp import MpsWereadMP, WereadMPAPIError, extract_mp_content
from tools.fix import fix_html

LIMIT = int(sys.argv[1]) if len(sys.argv) > 1 else 10
INTERVAL = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

db = sqlite3.connect("/app/data/db.db")
cur = db.cursor()
model = MpsWereadMP()
model._load_weread_auth()  # 显式加载wx.lic里的微信读书Cookie

rows = cur.execute("""
    SELECT a.id, a.title FROM articles a
    WHERE (a.content IS NULL OR a.content = '')
    ORDER BY a.fix_fail_count ASC, a.created_at DESC
    LIMIT ?
""", (LIMIT,)).fetchall()

ok = fail = empty = 0
interval = INTERVAL
t0 = time.time()
for aid, title in rows:
    review_id = aid.split("-", 1)[1] if "-" in aid else aid
    try:
        raw = model._get_mp_content(review_id)
        content = extract_mp_content(raw)
    except WereadMPAPIError as e:
        fail += 1
        cur.execute("UPDATE articles SET fix_fail_count = COALESCE(fix_fail_count,0)+1 WHERE id=?", (aid,))
        db.commit()
        print(f"{datetime.datetime.now():%H:%M:%S} ERR  {title[:26]} | {e.message[:70]}", flush=True)
        interval = min(interval * 1.7, 240)
        time.sleep(interval)
        continue
    except Exception as e:
        fail += 1
        print(f"{datetime.datetime.now():%H:%M:%S} EXC  {title[:26]} | {str(e)[:70]}", flush=True)
        interval = min(interval * 1.7, 240)
        time.sleep(interval)
        continue

    if content and len(content.strip()) > 30:
        cur.execute(
            "UPDATE articles SET content=?, content_html=?, has_content=1, status=1, fix_fail_count=0 WHERE id=?",
            (content, fix_html(content), aid),
        )
        db.commit()
        ok += 1
        print(f"{datetime.datetime.now():%H:%M:%S} OK   {title[:26]} | len={len(content)} | 间隔降至{interval:.1f}s", flush=True)
        interval = max(INTERVAL, interval * 0.85)
    else:
        empty += 1
        cur.execute("UPDATE articles SET fix_fail_count = COALESCE(fix_fail_count,0)+1 WHERE id=?", (aid,))
        db.commit()
        print(f"{datetime.datetime.now():%H:%M:%S} EMPTY {title[:26]} | 正文为空", flush=True)
        interval = min(interval * 1.3, 240)
    time.sleep(interval)

print(f"批完成: 成功 {ok} / 失败 {fail} / 空 {empty}, 耗时 {time.time()-t0:.0f}s")
