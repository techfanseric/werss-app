import fs from "node:fs";

// 占位符由 process_chunk.py / canary.py 注入:
//   __COMPANY__  JSON: {company_id, name, short, code}
//   __MODE__     "add" | "canary" (canary 只搜索不添加,用于风控探测)
//   __SPACE_FILE__  本 worker 的 taskSpace id 存放路径
//   __SPACE_NAME__  本 worker 的 taskSpace 名称
//   __APP_URL__     we-mp-rss 地址
//   __ADMIN_USER__ / __ADMIN_PASS__  管理端登录凭据(来自 config.env)
const company = __COMPANY__;
const mode = "__MODE__";
const spaceFile = "__SPACE_FILE__";
const spaceName = "__SPACE_NAME__";
const appUrl = "__APP_URL__";
const adminUser = "__ADMIN_USER__";
const adminPass = "__ADMIN_PASS__";

function result(o) { console.log("RESULT:" + JSON.stringify(o)); }

// ---- 空间管理:每个 worker 复用自己的 space ----
let task;
try {
  const id = parseInt((fs.readFileSync(spaceFile, "utf8") || "").trim());
  if (!id) throw new Error("no id");
  task = await taskSpace(id);
} catch (e) {
  task = await taskSpace(spaceName);
  try { fs.writeFileSync(spaceFile, String(task.spaceId)); } catch {}
}
let page = null;
const existingPages = await task.pages();
page = existingPages.length ? existingPages[existingPages.length - 1] : await task.newPage();

async function ensureApp() {
  // 复用已有页面(防页面预算耗尽);导航失败才关旧换新
  let ok = false;
  for (let attempt = 0; attempt < 2 && !ok; attempt++) {
    try {
      await page.goto(appUrl);
      await page.waitForLoadState();
      ok = await page.evaluate(() => document.readyState === "complete");
    } catch (e) {
      ok = false;
    }
    if (!ok && attempt === 0) {
      try { await page.close().catch(() => {}); } catch {}
      page = await task.newPage();
    }
  }
  if (!ok) throw new Error("app page navigation failed twice");
  await page.waitForTimeout(1800);
  const loginVisible = await page.evaluate(
    () => !!document.querySelector("input[placeholder='请输入帐号']")
  );
  if (loginVisible) {
    await page.fill("input[placeholder='请输入帐号']", adminUser);
    await page.fill("input[placeholder='请输入密码']", adminPass);
    await page.click("loc=role:button[name='登录']");
    await page.waitForTimeout(3500);
  }
}

// ---- 候选搜索词:短名、短名+招聘、去掉法务后缀的全名、全名+招聘 ----
function clean(s) {
  return (s || "")
    .replace(/[\s*＊]/g, "")
    .replace(/^(SST|ST|ＳＴ)/i, "")
    .replace(/A$/, "");
}
function buildCandidates() {
  const s = clean(company.short);
  const base = (company.name || "").replace(/(控股集团|集团|控股)?股份有限公司$/, "").replace(/(集团|控股)?有限公司$/, "");
  const out = [];
  for (const x of [s + "招聘", s, base + "招聘", base]) {
    if (x && x.length >= 2 && !out.includes(x)) out.push(x);
  }
  return out;
}

// 某个公众号名是否匹配核心词:去掉核心词后剩余部分只能是中性修饰词
function isMatch(opt, core) {
  if (!opt.includes(core)) return false;
  const rest = opt.split(core).join("");
  return /^(招聘|集团|股份|控股|公司|官方|招聘号|招聘平台|招聘中心|招聘官方号|号|平台|中心|[A-Za-z0-9])*$/.test(rest);
}

async function openDialog() {
  await page.evaluate(() => {
    const b = [...document.querySelectorAll("button")].find(
      (x) => x.textContent.trim() === "订阅" && x.getClientRects().length
    );
    b && b.click();
  });
  await page.waitForTimeout(600);
  await page.evaluate(() => {
    const items = [...document.querySelectorAll("li, .arco-dropdown-option")].filter(
      (x) => x.textContent.trim() === "添加公众号" && x.getClientRects().length
    );
    items[0] && items[0].click();
  });
  await page.waitForSelector("input[placeholder='请输入公众号名称']", { state: "visible", timeout: 8000 });
  await page.waitForTimeout(400);
}

async function readOptions(kw) {
  // 读两次,避免读到加载中的空列表
  const read = () =>
    page.evaluate(() => {
      const pops = [...document.querySelectorAll(".arco-trigger-popup")].filter(
        (p) =>
          p.getClientRects().length &&
          !p.textContent.includes("English") && // 排除语言选择下拉
          (p.querySelector(".arco-select-option") || p.querySelector(".arco-select-dropdown"))
      );
      const p = pops[pops.length - 1];
      if (!p) return null;
      return [...p.querySelectorAll(".arco-select-option")].map((o) => o.textContent.trim());
    });
  let opts = await read();
  if (opts === null || opts.length === 0) {
    await page.waitForTimeout(1300);
    opts = await read();
  }
  return opts || null;
}

async function searchOptions(kw) {
  await page.click("input[placeholder='请输入公众号名称']");
  await page.waitForTimeout(250);
  await page.keyboard.press("ControlOrMeta+a");
  await page.keyboard.press("Delete");
  await page.keyboard.type(kw);
  for (let t = 0; t < 8; t++) {
    await page.waitForTimeout(800);
    const opts = await readOptions(kw);
    if (opts !== null && opts.length >= 0 && opts !== undefined) {
      if (opts.length > 0) return opts;
      if (t >= 3) return []; // 弹层在但始终为空 = 无结果
    }
  }
  return [];
}

async function pickAndSubmit(target) {
  const clicked = await page.evaluate((t) => {
    const pops = [...document.querySelectorAll(".arco-trigger-popup")].filter((p) => p.getClientRects().length);
    for (const p of pops) {
      const el = [...p.querySelectorAll(".arco-select-option")].find((o) => o.textContent.trim() === t);
      if (el) { el.click(); return true; }
    }
    return false;
  }, target);
  if (!clicked) return false;
  await page.waitForTimeout(900);
  const ok = await page.evaluate(() => !!document.querySelector("input[placeholder='请输入公众号ID']")?.value);
  if (!ok) return false;
  await page.click("loc=role:button[name='添加订阅']");
  for (let t = 0; t < 12; t++) {
    await page.waitForTimeout(700);
    const gone = await page.evaluate(() => !document.querySelector("input[placeholder='请输入公众号名称']"));
    if (gone) return true;
  }
  return true;
}

async function closeDialog() {
  await page.keyboard.press("Escape");
  await page.waitForTimeout(400);
  await page.evaluate(() => {
    const btns = [...document.querySelectorAll(".arco-modal button")].filter(
      (x) => x.getClientRects().length && /取\s*消/.test(x.textContent)
    );
    btns[0] && btns[0].click();
  });
  await page.waitForTimeout(400);
}

// ---- 主流程 ----
try {
  await ensureApp();

  if (mode === "canary") {
    await openDialog();
    const opts = await searchOptions("平安银行");
    await closeDialog();
    result({ status: "canary", found: (opts || []).length });
    process.exit(0);
  }

  const cands = buildCandidates();
  const tried = [];
  let picked = null;

  await openDialog();
  for (const cand of cands) {
    tried.push(cand);
    const opts = await searchOptions(cand);
    if (!opts || opts.length === 0) continue;
    const core = cand.replace(/招聘$/, "");
    const matches = opts.filter((o) => isMatch(o, core));
    const withZp = matches.filter((o) => o.includes("招聘"));
    const target = withZp.sort((a, b) => a.length - b.length)[0] || matches.find((o) => o === core) || null;
    if (target) { picked = target; break; }
  }

  let status = "not_found", name = "";
  if (picked) {
    const ok = await pickAndSubmit(picked);
    status = ok ? "added" : "submit_failed";
    name = picked;
  }
  await closeDialog();
  result({ status, name, tried, company_id: company.company_id });
} catch (err) {
  result({ status: "JS_ERROR", detail: String(err).slice(0, 200), company_id: company.company_id });
}
