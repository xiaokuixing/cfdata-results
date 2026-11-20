# Telegram 转发 IP → 自动测速 → 进 pool

把群里分享的 IP 转发给 Telegram bot，仓库里的 `shared-ips.txt` 会自动更新；
本机定时任务发现更新后，用本地 cfdata 做非标优选，达标结果由 cfdata 自己上传成 `results.txt`，
再由仓库现有的 Action 合并进 `pool.txt`。

```
TG 转发 IP ──▶ Worker ──▶ shared-ips.txt
                              │  GitHub API 下载后以 -nsbfile 交给 cfdata
                              ▼
                  本地 cfdata 非标优选（条件见第 6 节）
                              │  cfdata -github 上传
                              ▼
                        results.txt ──Action──▶ pool.txt

TG 发「重测 + IP」──▶ Worker ──▶ agent/retest-request.json
                              │  本机 agent 每分钟取一次
                              ▼
                   同一套 cfdata 测速 → 汇报发回 Telegram
```

- 收集端（Worker）只做提取、去重、写文件，不测速。
- 测速、筛选、上传全部由 cfdata 完成，条件可以随时在 `agent/agent.config.json` 里改。
- 你正在用的 `pool.txt` 不会被这个流程直接改写，仍然由现有 `update_pool.py` 合并。

---

## 1. 建 bot

1. Telegram 搜索 `@BotFather`，发送 `/newbot`，按提示起名。
2. 记下返回的 token，形如 `123456:AAE...`。
3. 搜索 `@userinfobot`，给它发一条消息，记下你的 **user id**（一串数字）。

## 2. 建 GitHub token

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token。
2. Repository access 只选 `xiaokuixing/cfdata-results`。
3. Permissions → Repository permissions → **Contents: Read and write**（Metadata 会自动带上 Read）。
4. 生成后保存到本地文件：

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.cfdata-results" | Out-Null
Set-Content "$env:USERPROFILE\.cfdata-results\gh-token.txt" "github_pat_xxxxxxxx" -NoNewline
```

这个 token 同时给 Worker 和 cfdata 用。只给了这一个仓库的 Contents 权限，泄露影响可控。

## 3. 部署 Worker

1. Cloudflare 控制台 → Workers & Pages → Create → Worker，名字随意。
2. 把 `worker/worker.js` 的内容整个粘贴进在线编辑器，Deploy。
3. Settings → Variables and Secrets，添加：

| 名称 | 类型 | 值 |
| --- | --- | --- |
| `BOT_TOKEN` | Secret | BotFather 给的 token |
| `GH_TOKEN` | Secret | 第 2 步的 fine-grained token |
| `GH_REPO` | Text | `xiaokuixing/cfdata-results` |
| `ALLOWED_USER_IDS` | Text | 你的 user id（多个用逗号） |
| `WEBHOOK_SECRET` | Secret | 自己随便生成一串，比如 32 位随机字符 |
| `GH_PATH` | Text | 可省略，默认 `shared-ips.txt` |
| `GH_BRANCH` | Text | 可省略，默认 `main` |
| `GH_PATH_OTHER` | Text | 可省略，默认 `shared-ips-other.txt`（非 CF 网段的 IP 存这里） |
| `DEFAULT_PORTS` | Text | 可省略，默认 `443`（消息里没写端口时用） |
| `MAX_LINES` | Text | 可省略，默认 `200`（`shared-ips.txt` 只保留最新这么多条） |
| `NOTIFY_SECRET` | Secret | 本地 agent 回传测速汇报用的密钥，随便生成一串 32 位以上随机字符 |
| `GH_CMD_PATH` | Text | 可省略，默认 `agent/retest-request.json`（重测请求文件） |
| `GH_QUEUE_PATH` | Text | 可省略，默认 `agent/report-queue.json`（汇报队列文件） |

4. 记下 Worker 地址，例如 `https://cfdata-inbox.xxx.workers.dev`。
5. 注册 webhook：

```powershell
$body = @{
    url            = "https://cfdata-inbox.xxx.workers.dev"
    secret_token   = "你填的 WEBHOOK_SECRET"
    allowed_updates = @("message")
} | ConvertTo-Json

Invoke-RestMethod -Method Post `
    -Uri "https://api.telegram.org/bot<BOT_TOKEN>/setWebhook" `
    -ContentType "application/json" -Body $body
```

6. 给 bot 发 `/id`，确认能收到回复；再转发一条带 IP 的群消息，应该回复「已收录 N 个新 IP」。

`shared-ips.txt` 采用**新 IP 在前**的写入方式，这样 cfdata 会优先测到最近分享的节点。

消息里的 IP 会按网段自动分流：

- Cloudflare 网段 → `shared-ips.txt`，走完整的自动测速流程
- 其他网段 → `shared-ips-other.txt`，只收集不自动测（cfdata 的链路复验探针和测速源都是 CF 的，非 CF 的 IP 测了也过不了，混进 `pool.txt` 还会让节点不可用）

bot 的回复会分别告诉你两边各收录了多少。

## 4. 配置本地 agent

```powershell
Copy-Item agent\agent.config.example.json agent\agent.config.json
notepad agent\agent.config.json
```

必须改的两项：

- `cfdataExe`：cfdata 可执行文件的完整路径
- `tokenFile`：默认就是 `%USERPROFILE%\.cfdata-results\gh-token.txt`

先看一遍最终命令（不会真的运行）：

```powershell
powershell -ExecutionPolicy Bypass -File .\agent\agent.ps1 -SelfTest
```

手动跑一次：

```powershell
powershell -ExecutionPolicy Bypass -File .\agent\agent.ps1 -Force
```

`-Force` 表示不管 `shared-ips.txt` 有没有变化都跑一次。

## 5. 注册定时任务

```powershell
powershell -ExecutionPolicy Bypass -File .\agent\install-task.ps1 -Minutes 1
```

- 默认每 1 分钟检查一次；`shared-ips.txt` 没变化时只发一个请求就退出。这样群里转发的 IP 和聊天里的「重测」都能在 1 分钟内开始处理。
- 删除任务：`... -File .\agent\install-task.ps1 -Remove`
- 日志在 `agent/logs/agent-yyyyMMdd.log`。
- 电脑关机期间不会测，开机后的下一轮会自动补上。

## 6. 测速条件

都在 `agent/agent.config.json` 的 `params` 里，改完下一轮生效：

| 字段 | cfdata 参数 | 说明 |
| --- | --- | --- |
| `threads` | `-nsbthreads` | 延迟扫描并发，默认 100 |
| `speedThreads` | `-nsbspeedtest` | 测速线程，1 最准；0 表示不测速 |
| `speedMin` | `-nsbspeedmin` | 合格门槛，MB/s，默认 10 |
| `speedLimit` | `-nsbspeedlimit` | 测速结果数量上限，凑够就停，默认 100 |
| `resultLimit` | `-nsbresultlimit` | 进入测速阶段的最大条数，默认 200 |
| `delay` | `-nsbdelay` | 延迟门槛（毫秒），默认 350，0 = 不筛 |
| `tls` | `-nsbtls` | 目标端口是否按 TLS 访问，默认 true |
| `relink` | `-relink` | 链路复验，默认 true |

另外：

- `sourceMode`：默认 `api`，通过 `api.github.com` 取文件（国内比 raw 稳），下载后以 `-nsbfile` 交给 cfdata；改成 `url` 才会用 `-nsbsourceurl` 直接拉 raw。
- `sourceUrl`：只在 `sourceMode=url` 时生效，留空则自动用 `https://raw.githubusercontent.com/<repo>/<branch>/<inboxPath>`。
- `proxy`：只影响 cfdata 的管理面请求（下载、上传等），扫描测速仍然直连。留空则用系统代理环境变量。
- 想完全不筛、把测到的全传上去：把 `outqualified` 对应的导出改成 all —— 目前固定为 `qualified`，需要改 `agent.ps1` 里这一行。

注意：`speedThreads = 0` 时不会有「合格」结果，cfdata 也就不会上传任何东西。

cfdata 网页模式里的设置只影响网页手动运行，不会同步给计划任务；要改自动任务的条件，就改这个文件。

`shared-ips.txt` 由 Worker 自动裁剪，只保留最新 `MAX_LINES` 条（默认 200），新 IP 在前；想留更多就把 Worker 的 `MAX_LINES` 调大。这样每轮耗时可控。

## 7. 测速汇报

每轮测速结束后，agent 会用 bot 私聊你一条汇总：

```
📊 本轮测速完成 · 11-20 22:43
条件：延迟 ≤ 350ms · 速度 ≥ 10MB/s · 并发 1

来源 12 个 → 链路可用 7 个 → 实际测速 7 个
合格 1 个 · 已上传 1 个到 results.txt
耗时 108 秒

✅ 162.159.160.28:443 — 13.26MB/s
❌ 104.18.41.26:443 — 2.19MB/s
❌ 172.64.229.159:443 — 1.48MB/s
❌ 162.159.237.150:443 — 0.79MB/s
❌ 104.16.147.56:443 — 0.68MB/s

https://github.com/xiaokuixing/cfdata-results/blob/main/results.txt
```

- 来源：`shared-ips.txt` 的行数
- 链路可用：通过 relink 复验的条数
- 实际测速：真正进入测速阶段的条数
- 合格 / 已上传：达到门槛并被写进 `results.txt` 的条数；0 个时 cfdata 不会上传，消息里会写「未上传」
- 下面的列表是**所有实际测过速的 IP**，按速度从快到慢排；✅ 达标、❌ 未达标（测速失败的会显示原因）
- 只上传 ✅ 的；列表最多列 60 条，超过会写「另有 N 个未列出」，esults.txt 里永远是完整结果

相关配置：

| 字段 | 说明 |
| --- | --- |
| `notify` | 默认 `true`；设成 `false` 就不发汇报 |
| `telegramChatId` | 你的 user id |
| `telegramTokenFile` | bot token 文件，默认 `%USERPROFILE%\.cfdata-results\bot-token.txt` |
| `telegramProxy` | 可选，手动指定发 Telegram 的代理，例如 `http://127.0.0.1:7890` |

网络说明（汇报怎么送到你手机）：

1. 优先走 Worker：agent 把汇报 POST 到 Cloudflare Worker 的 `/notify`，由 Worker 调 Telegram。代理开着时几乎立刻到。
2. Worker 连不上（例如国内直连不上 `workers.dev`）：agent 把汇报写进仓库的 `agent/report-queue.json`（走 `api.github.com`，国内可直连）。
3. Worker 的 Cron 每 2 分钟检查一次队列，有内容就转发给你并清空队列。最坏多等 2 分钟，**不需要本机开代理**。
4. 以上都失败才会落到 `agent/pending-reports/`，下一轮补发，最多保留 20 条。

- `/notify` 用 `NOTIFY_SECRET` 鉴权；`/flush` 只会发给 `ALLOWED_USER_IDS` 里的 chat，不会被别人拿来做转发器。
- 测速本身始终直连，和代理无关（Go 写的 cfdata 不读 Windows 系统代理）。

单轮最长运行 `timeoutMinutes`（默认 90 分钟），超时会被强制结束并记一条 ⚠️ 汇报。计划任务每 1 分钟触发一次，上一轮没跑完时这一轮直接跳过。
## 8. 重测指定 IP

### 8.1 在 Telegram 里直接发（推荐）

私聊 bot，把「重测」和 IP 放在同一条消息里，格式随意：

```
重测
162.159.160.28:443
104.16.148.10 443
１７２.64.79.24：2096
```

- 关键词：`重测`、`重新测`、`retest`、`/retest`，放在消息任意位置都行
- IP 支持 `ip:端口`、`ip 端口`、`[IPv6]:端口`、中文全角标点，一次最多 200 个
- bot 先回一条「已收到 N 个 IP，进入测速队列」
- 本机 agent 每分钟取一次请求，测完把完整的测速汇报发回这个聊天（就是第 7 节那种格式，含每个 IP 的速度排名）
- 非 CF 网段会提示「大概率会在链路复验被淘汰」
- 消息里同时有别的内容也没关系，只提取 IP；含「重测」的消息不会被写进 `shared-ips.txt`

> 本机没开机 / 没网时，请求会留在 `agent/retest-request.json` 里，开机后下一轮自动跑。

### 8.2 本机手动重测

想单独重测几个 IP（不改 `shared-ips.txt`）：

1. 打开 `D:\cfdata\cfdata-agent\retest.txt`，一行一个填进去（`#` 开头是注释）：

```
162.159.160.28:443
104.16.148.10 443
```

2. 双击 `D:\cfdata\cfdata-agent\retest.cmd`。

或者命令行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\cfdata\cfdata-agent\agent.ps1 -Force -SourceFile D:\cfdata\cfdata-agent\retest.txt
```

行为说明：

- 用的是同一套测速参数；合格的照样由 cfdata 上传 `results.txt`，再由 Action 合并进 `pool.txt`
- 汇报开头会标 `🔁 手动重测`，速度列表和平时一样
- 不会更新 `state.json`，所以不会影响定时任务对"来源有没有变化"的判断
- 重测变慢不会拖累 `pool.txt`：`update_pool.py` 对同一个地址只保留历史最高速度

想把 `shared-ips.txt` 里的全部 IP 整体重测一遍，直接用 `-Force`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\cfdata\cfdata-agent\agent.ps1 -Force
```
## 9. 排错

- **bot 不回消息**：先访问 Worker 地址，返回 `cfdata telegram inbox worker` 说明 Worker 正常；再检查 webhook 是否指向正确地址、`WEBHOOK_SECRET` 是否和 `setWebhook` 一致。
- **回复「未配置 ALLOWED_USER_IDS」**：环境变量没生效，或 user id 填错。
- **回复「没找到可用 IP」**：消息里没有 `ip:端口`，或格式/端口不合法。非 CF 网段的 IP 会写进 `shared-ips-other.txt`，不参与测速。
- **cfdata 拉不到 sourceUrl**：`raw.githubusercontent.com` 需要匿名可访问，仓库必须是 public；国内访问不稳时把 `sourceUrl` 换成镜像地址，或在 `proxy` 里填本地代理。
- **agent 日志显示 401/403**：token 过期、没给 Contents 写权限，或 token 文件路径不对。
- **agent 日志显示 `[config]`**：cfdata 第一次运行会在 exe 目录生成配置文件并退出，脚本会自动重试一次；如果仍失败，手动跑一次 cfdata 让它生成配置即可。
- **cfdata 报 `flag provided but not defined`**：本地 cfdata 版本太旧，升级到最新 Release 再试（需要支持 `-nsbsourceurl`、`-github`、`-skipgeo`）。
- **cfdata 上传了但 pool 没变**：检查 Action 是否成功、`results.txt` 是否真的被覆盖；只有合格结果才会被上传。

## 10. 文件说明

| 文件 | 作用 |
| --- | --- |
| `shared-ips.txt` | bot 收集的原始 IP，新的在前 |
| `shared-ips-other.txt` | bot 收集到的非 CF 网段 IP，只存不测 |
| `results.txt` | 每次 cfdata 测速后覆盖写入的合格结果 |
| `pool.txt` | 历史累积池（你正在用的文件） |
| `agent/retest-request.json` | Telegram 重测请求，处理完会标记 `status: done` |
| `agent/report-queue.json` | 汇报队列，Worker 定时转发后清空 |
| `worker/worker.js` | Telegram → GitHub 收集端 + 汇报转发 |
| `agent/agent.ps1` | 本地增量测速 |
| `agent/agent.config.example.json` | 参数模板 |
| `agent/install-task.ps1` | 注册/删除计划任务 |
| `agent/retest.txt` / `agent/retest.cmd` | 手动重测指定 IP |