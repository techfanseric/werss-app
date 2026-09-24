#!/bin/bash
# 一键发布（只在发布机/这台机器运行一次）：
#   bash bin/publish.sh <github用户名/仓库名 或 完整SSH/HTTPS地址>
# 做四件事：① 设置/更新 git remote origin → ② 把仓库地址写进 config.example.env
# （随代码分发给所有机器，新机零配置自动更新）→ ③ 提交 → ④ 按 VERSION 打 tag 并推送。
# 之后在 GitHub 上把该 tag 发成 Release（或开启自动 Release），全部机器一天内自动更新。
set -e
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ARG="${1:-}"
[ -z "$ARG" ] && { echo "用法: bash bin/publish.sh <用户名/仓库 或 git地址>"; exit 1; }

# 归一化：u/r → https://github.com/u/r.git；完整地址原样
case "$ARG" in
  *github.com*) URL="$ARG" ;;
  */*) URL="https://github.com/$ARG.git" ;;
  *) echo "参数应为 用户名/仓库名 或完整 git 地址"; exit 1 ;;
esac
SLUG=$(printf '%s' "$URL" | sed -E 's#\.git$##; s#^git@github\.com:##; s#^https?://github\.com/##')

cd "$WERSS_ROOT"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$URL" && echo "remote origin 已更新: $URL"
else
  git remote add origin "$URL" && echo "remote origin 已添加: $URL"
fi

# 地址写入模板（随代码分发；本机 config.env 不动）
python3 - "$WERSS_ROOT/config.example.env" "$SLUG" <<'PY'
import re, sys
path, slug = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
s = re.sub(r"(WERSS_GITHUB_REPO=).*", r"\1" + (slug and "${WERSS_GITHUB_REPO:-%s}" % slug or ""), s, count=1)
s = s.replace("# 仓库 slug，发布后填入，例如 ericyim/werss-app；留空则跳过自动更新",
              "# 仓库地址（由 bin/publish.sh 写入，随代码分发；机器端无需任何配置）")
open(path, "w", encoding="utf-8").write(s)
PY
echo "config.example.env 已写入 WERSS_GITHUB_REPO=$SLUG"

V=$(cat VERSION)
git add -A && git commit -m "publish $V → $SLUG" --quiet || true
git tag -f "$V"
echo "提交并打标签 $V"
echo "推送到 GitHub…（可能要求登录）"
git push -u origin main --tags
echo
echo "✓ 完成。最后一步：到 https://github.com/$SLUG/releases 把 $V 发成 Release"
echo "  （或仓库开启自动生成 Release）。之后所有机器 24 小时内自动更新。"
