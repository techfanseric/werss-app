#!/usr/bin/env python3
"""清理 ego taskSpace 的多余页面(防页面预算耗尽)。
用法: python3 cleanup_space.py <space_N.id 文件名>
输出 CLEANED n(关掉的页面数)。原 /tmp/cleanup_space.py 丢失后的重写版。
"""
import json, os, subprocess, sys

BATCH = os.path.dirname(os.path.abspath(__file__))

space_file = sys.argv[1] if len(sys.argv) > 1 else ""
path = os.path.join(BATCH, space_file) if space_file and not os.path.isabs(space_file) else space_file
if not path or not os.path.exists(path):
    print("CLEANED 0 (no space id file)")
    sys.exit(0)

js = (
    "import fs from 'node:fs';\n"
    "const id = parseInt(fs.readFileSync(" + json.dumps(path) + ", 'utf8').trim());\n"
    "let task;\n"
    "try { task = await taskSpace(id); } catch (e) { console.log('CLEANED 0 (space gone)'); process.exit(0); }\n"
    "const pages = await task.pages();\n"
    "// 保留最后一个页面(复用入口),关掉其余\n"
    "for (let i = 0; i < pages.length - 1; i++) {\n"
    "  try { await pages[i].close(); } catch (e) {}\n"
    "}\n"
    "console.log('CLEANED ' + Math.max(0, pages.length - 1));\n"
)

r = subprocess.run(["ego-browser", "nodejs"], input=js, capture_output=True, text=True, timeout=60)
out = (r.stdout or "") + (r.stderr or "")
for line in out.splitlines():
    if line.startswith("CLEANED"):
        print(line)
        sys.exit(0)
print("CLEANED 0 (no output: " + out[-150:].replace("\n", " ") + ")")
