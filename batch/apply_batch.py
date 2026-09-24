#!/usr/bin/env python3
"""把 Ego Lite 采集到的正文批量写回数据库。用法: apply_batch.py <batch.json>"""
import sys, json
sys.path.insert(0, "/app")
import init_sys as init
init.init()
from core.db import DB
from tools.fix import fix_html

batch = json.load(open(sys.argv[1], encoding="utf-8"))
db = DB.get_session()
from core.models.article import Article
ok = dead = empty = 0
for item in batch:
    a = db.query(Article).filter(Article.id == item["id"]).first()
    if not a:
        continue
    if item.get("dead"):
        a.fix_fail_count = 99  # 标记为链接失效,不再重试
        dead += 1
    elif item.get("html") and len(item["html"]) > 100:
        a.content = item["html"]
        a.content_html = fix_html(item["html"])
        a.has_content = 1
        a.status = 1
        a.fix_fail_count = 0
        ok += 1
    else:
        empty += 1
db.commit()
print(f"APPLIED ok={ok} dead={dead} empty={empty}")
