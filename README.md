# werss-app —— 微信公众号采集系统（便携打包版）

把原「we-mp-rss Docker 容器 + 批量采集脚本 + ego 浏览器自动化 + 保活」整套工作
打包成一个可整体搬家的目录。**新机器只需双击一个文件**即可恢复全部工作。

## 目录一览（日常只碰 4 个双击入口）

| 文件 | 作用 |
|---|---|
| `安装.command` | **新机一键安装**：自动装 Docker Desktop 和 ego lite → 拉镜像 → 装开机自启+保活 → 数据可选导入（导入步骤会说明价值） |
| `WERSS控制台.app` | 日常使用：确保全套运行、弹状态通知、打开管理页 `http://localhost:8001` |
| `交接导出.command` | 换机前在**旧机**双击：打出约 40MB 备份包（自动恢复运行） |
| `交接导入.command` | 换机后在**新机**双击：从备份包恢复（自动三核对：订阅数/文章数/待处理余量） |

其余：`bin/`（运维脚本）、`batch/`（采集脚本）、`data/`（数据库与授权）、
`companies.csv`（公司台账）、`config.env`（全部配置）、`launchd/`（自启）。

## 场景一：新电脑第一次启用（约 30–60 分钟，大部分是等待）

1. 把整个 `werss-app` 文件夹拷到新机（U盘/AirDrop 均可，任意位置）。
   > 若双击被 macOS 拦截（"无法验证开发者"）：右键点文件 →「打开」→ 再点「打开」，一次即可。
2. 双击 `安装.command`，全自动：装 Docker Desktop → 装 ego lite（只需完成一次
   首次引导 onboarding，安装器会等你）→ 拉 4.3GB 镜像 → 装开机自启+每 30 分钟保活。
3. 走到「数据」步骤时安装器会停下说明：
   - **有备份包** → 导入 = 恢复已订阅公众号、文章库、剩余采集队列、微信授权，从断点继续；
   - **没有** → 空白开始（以后随时双击 `交接导入.command` 补导）。
4. 完成。如弹系统通知要求扫码（微信读书授权/平台登录），按通知打开的页面扫一下即可。

之后日常零操作：开机自动恢复全套；需要人时 Mac 右上角弹系统通知。

## 场景二：两机交接（每次约 10 分钟）

1. **旧机**：双击 `交接导出.command`（采集暂停 1–2 分钟）→ 得到
   `backups/werss-backup-日期.tar.gz`（约 40MB）。
2. 把备份包传给新机（AirDrop/U盘/网盘）。
3. **新机**：双击 `交接导入.command`，把备份包拖进窗口回车 → 自动换数据、起容器、
   起采集 → 通知报告核对结果。
4. **纪律：同一时间只有一台机器在采集**（SQLite 单文件库，两台同写会分叉无法合并）。
   交接完成后旧机不要再跑采集（双击导出后它虽会恢复运行，请手动在旧机执行
   `bash bin/stop.sh` 停掉，或直接不管它——开始采集前永远先导入最新备份）。

## 需要「人」的时刻（通知只做提示，操作走控制台）

提醒是 macOS 右上角横幅+声音（稳定必达）。**通知本体是信息提示，请勿点击**
（系统通知归属「脚本编辑器」，点开会打开它）——所有操作通过
**WERSS控制台.app**（建议拖进 Dock，一键直达）：

- **微信读书授权失效**（约 24h 过期或换 IP）：双击 WERSS控制台 → **自动登录并
  直达扫码页**（ego 浏览器，无需手动登录，账密在通知正文里备查）。影响文章正文，
  不影响账号添加。
- **公众号平台登录过期**：换公众号账号登录可得新的搜索配额。
- **Docker 未恢复 / 应用未就绪 / 连续 3 次保活失败**：横幅提醒人工处理，
  `bash bin/status.sh` 看详情。
- **限流**：runner 自动冷却 40 分钟，金丝雀词轮换探测，无需人工。

> 为什么不用「点通知直达」：macOS 上第三方/脚本通知的点击行为归系统管
> （terminal-notifier 权限会被静默关死、osascript 通知点了开脚本编辑器），
> 均不可控。控制台.app 一键直达等效且 100% 可靠。

### 可选：让横幅不自动收起

系统设置 → 通知 → **脚本编辑器（Script Editor）** → 通知样式选 **「提醒」**，
werss 的横幅就会常驻右上角直到手动关掉。

## 自动更新（GitHub Release，机器端零配置）

- **发布端（唯一要做的）**：在开发机上改完代码 → 更新 `VERSION`（如 `v1.2.3`）→ 提交 →
  `bash bin/publish.sh 用户名/werss-app`（设 remote、写地址入模板、打 tag、推送）→
  到 GitHub Releases 把 tag 发成 Release。
- **机器端（什么都不用做）**：仓库地址随代码分发，各机器保活每天自动检查一次
  Release，有新版 → 自动下载覆盖**代码** → 重装自启 → 重启 runner → 通知。
  `data/`、`companies.csv`、`config.env`、采集队列与进度**永不被更新触碰**；
  更新前代码自动备份到 `backups/code-pre-update-*`。
- 手动：`bash bin/update.sh --check`（只看新版）/ `bash bin/update.sh`（立即更新）。
- 注意：自动更新走匿名 API，仓库需为 **public**；若改 private，各机器需配置
  GitHub token（`curl -H "Authorization: Bearer …"`），不建议。

## 常用命令（可选，双击入口已覆盖日常）

```bash
bash bin/start.sh      # 全套启动（Docker→容器→runner）
bash bin/stop.sh       # 停 runner+容器（数据保留）
bash bin/status.sh     # 一行状态：docker/容器/应用/runner/进度/文章数/授权
bash bin/keepalive.sh  # 手动跑一次保活（launchd 每 30 分钟自动跑）
bash bin/export.sh     # 导出备份（同 交接导出.command）
bash bin/import.sh 备份包路径   # 导入备份（同 交接导入.command）
bash bin/uninstall_launchd.sh   # 卸载自启保活（回退用）
```

## 配置（`config.env`，本机文件不入库）

模板为 `config.example.env`（入库；安装器自动复制为 `config.env`）。内容：端口
（默认 8001）、容器名、镜像（锁定与原系统同一构建）、管理端账号密码、采集节奏
（防风控参数，与原系统一致，**不建议调快**）、GitHub 仓库地址（用于自动更新）。

## 架构与数据

```
launchd(每30分钟+登录) → keepalive.sh
  ├─ Docker Desktop → docker compose → 容器 we-mp-rss (:8001, data/ 挂载)
  ├─ batch/run_forever.sh → process_chunk.py → ego-browser(自动登录) → Web UI 批量订阅
  │    └─ 进度: batch/slice*.jsonl(队列) + companies.csv(台账) + canary(风控探测)
  └─ 需要人时 → macOS 系统通知 + 打开扫码页
```

- 数据都在 `data/`（SQLite db.db、微信授权 wx.lic/key.lic、.secret_key）+
  `companies.csv` + `batch/slice*.jsonl`；备份包含以上全部。
- git 仓库只管代码；数据不入 git，走备份包。

## 故障排查

| 症状 | 处理 |
|---|---|
| 双击 .command 提示无法验证开发者 | 右键 → 打开 → 打开；或 `xattr -dr com.apple.quarantine ~/werss-app` |
| Docker 起不来 | 打开 Docker Desktop 看报错；保活 5 分钟自愈一次，连续 3 次失败会通知人工 |
| 容器起了但应用不通 | `docker logs --tail 50 we-mp-rss`；一般 2 分钟初始化，等一等 |
| runner 不跑 | `bash bin/status.sh` 看 slice 剩余；有剩余则 `bash bin/start.sh` |
| 限流（连续未找到） | 自动冷却 40 分钟；急用 `python3 batch/canary.py` 手动探测 |
| 导入后数字对不上 | 看 `logs/`；旧数据在 `backups/pre-import-*/`，未删除，可回退 |
| 彻底回退 | `bash bin/uninstall_launchd.sh` + `bash bin/stop.sh`，原 ZCode automation 可恢复 |

## 首次从原系统迁移（已完成，留档）

原系统位于 `~/.zcode/workspace/default/{we-mp-rss,werss_batch}`，本仓库为其重构打包：
路径全部收编到 `config.env`，admin 凭据改为运行时注入，补上丢失的 cleanup_space.py，
容器改 compose 管理（restart: unless-stopped，锁同版镜像），保活从 ZCode automation
改为 launchd 独立运行。原目录原样保留作归档，未做任何修改。
