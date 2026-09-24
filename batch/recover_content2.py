#!/usr/bin/env python3
"""存量文章正文恢复:微信读书列表接口拿新鲜链接 → 匹配存量 → 立即采正文。

用法: python3 recover_content2.py [运行小时数,默认5] [起始间隔秒,默认8]
自适应节奏:成功 0.8x 提速(下限5s),失败 1.6x 退避(上限300s)。
"""
import sys, time, datetime

sys.path.insert(0, "/app")
import init_sys as init
init.init()

from core.db import DB
from core.models.article import Article
from core.models.feed import Feed
from core.wx.model.weread_mp import MpsWereadMP, parse_mp_articles, build_mp_link_from_review_id
from core.article_content import sync_article_content

BUDGET = float(sys.argv[1] if len(sys.argv) > 1 else 5) * 3600
interval = float(sys.argv[2] if len(sys.argv) > 2 else 8)

session = DB.get_session()
model = MpsWereadMP()
model._load_weread_auth()

t0 = time.time()
done = ok = fail = 0

def log(msg):
    print(f"{datetime.datetime.now():%m-%d %H:%M:%S} {msg}", flush=True)

feeds = session.query(Feed).all()
log(f"开始恢复,共 {len(feeds)} 个账号,预算 {BUDGET/3600:.1f} 小时,起始间隔 {interval:.0f}s")

for feed in feeds:
    if time.time() - t0 > BUDGET:
        log("达到时间预算,停止")
        break
    pend = session.query(Article).filter(
        Article.mp_id == feed.id,
        (Article.content.is_(None)) | (Article.content == "")
    ).all()
    if not pend:
        continue
    book_id = feed.id
    # 拉新鲜链接列表(最多3页,每页间隔1秒)
    fresh = {}
    try:
        for offset in (0, 10, 20):
            payload = model._get_mp_articles_page(book_id, offset=offset)
            arts, group_count = parse_mp_articles(payload)
            for it in arts:
                aid = it["aid"]
                fresh[aid] = it.get("link") or build_mp_link_from_review_id(aid, book_id)
            time.sleep(1.2)
            if group_count == 0 or not arts:
                break
    except Exception as e:
        log(f"[{feed.mp_name[:14]}] 列表获取失败: {str(e)[:70]}")
        time.sleep(min(interval * 2, 240))
        continue

    matched = 0
    for a in pend:
        if time.time() - t0 > BUDGET:
            break
        aid = a.id.split("-", 1)[1] if "-" in a.id else ""
        if aid not in fresh:
            continue
        matched += 1
        a.url = fresh[aid]
        a.fix_fail_count = 0
        if hasattr(a, "fetch_started_at"):
            a.fetch_started_at = None
        session.commit()
        try:
            success, reason = sync_article_content(session, a, force=True)
        except Exception as e:
            success, reason = False, str(e)[:40]
        done += 1
        if success:
            ok += 1
            interval = max(5, interval * 0.8)
        else:
            fail += 1
            interval = min(interval * 1.6, 300)
        log(f"[{'OK' if success else 'FAIL'}] {feed.mp_name[:14]} | {a.title[:24]} | {reason} | 间隔{interval:.0f}s")
        time.sleep(interval)
        if time.time() - t0 > BUDGET:
            break
    log(f"[{feed.mp_name[:14]}] 待补{len(pend)} 匹配{matched} (累计 完成{done} 成功{ok} 失败{fail})")

log(f"恢复结束: 完成 {done}, 成功 {ok}, 失败 {fail}, 用时 {(time.time()-t0)/3600:.1f} 小时")
