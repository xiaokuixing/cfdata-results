# Telegram 转发 IP → 自动测速 → 进 pool

把群里分享的 IP 转发给 Telegram bot，仓库里的 `shared-ips.txt` 会自动更新；
本机定时任务发现更新后，用本地 cfdata 做非标优选，达标结果由 cfdata 自己上传成 `results.txt`，
再由仓库现有的 Action 合并进 `pool.txt`。

```
TG 转发 → Worker → shared-ips.txt
                        │  GitHub API 下载后以 -nsbfile 交给 cfdata
                        ▼
            本地 cfdata 非标优选（条件见第 6 节）
                        │  cfdata -github 上传
                        ▼
                  results.txt ──Action──▶ pool.txt
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
| `CF_ONLY` | Text | 可省略，默认 `true`（只收 Cloudflare 官方网段） |
| `DEFAULT_PORTS` | Text | 可省略，默认 `443`（消息里没写端口时用） |

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
powershell -ExecutionPolicy Bypass -File .\agent\install-task.ps1 -Minutes 10
```

- 默认每 10 分钟检查一次；`shared-ips.txt` 没变化时只发一个请求就退出。
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
| `speedLimit` | `-nsbspeedlimit` | 凑够多少个合格结果就停，默认 10 |
| `resultLimit` | `-nsbresultlimit` | 进入测速阶段的最大条数，默认 500 |
| `delay` | `-nsbdelay` | 延迟门槛（毫秒），0 = 不筛 |
| `tls` | `-nsbtls` | 目标端口是否按 TLS 访问，默认 true |
| `relink` | `-relink` | 链路复验，默认 true |

另外：

- `sourceMode`：默认 `api`，通过 `api.github.com` 取文件（国内比 raw 稳），下载后以 `-nsbfile` 交给 cfdata；改成 `url` 才会用 `-nsbsourceurl` 直接拉 raw。
- `sourceUrl`：只在 `sourceMode=url` 时生效，留空则自动用 `https://raw.githubusercontent.com/<repo>/<branch>/<inboxPath>`。
- `proxy`：只影响 cfdata 的管理面请求（下载、上传等），扫描测速仍然直连。留空则用系统代理环境变量。
- 想完全不筛、把测到的全传上去：把 `outqualified` 对应的导出改成 all —— 目前固定为 `qualified`，需要改 `agent.ps1` 里这一行。

注意：`speedThreads = 0` 时不会有「合格」结果，cfdata 也就不会上传任何东西。

cfdata 网页模式里的设置只影响网页手动运行，不会同步给计划任务；要改自动任务的条件，就改这个文件。

`shared-ips.txt` 会一直增长，旧 IP 排在后面。积累到几百条后建议手动清一次（保留最近需要的部分），否则每轮延迟扫描会越来越慢。

## 7. 排错

- **bot 不回消息**：先访问 Worker 地址，返回 `cfdata telegram inbox worker` 说明 Worker 正常；再检查 webhook 是否指向正确地址、`WEBHOOK_SECRET` 是否和 `setWebhook` 一致。
- **回复「未配置 ALLOWED_USER_IDS」**：环境变量没生效，或 user id 填错。
- **回复「没找到可用 IP」**：消息里没有 `ip:端口`，或 IP 不在 Cloudflare 官方网段（`CF_ONLY=false` 可关闭过滤）。
- **cfdata 拉不到 sourceUrl**：`raw.githubusercontent.com` 需要匿名可访问，仓库必须是 public；国内访问不稳时把 `sourceUrl` 换成镜像地址，或在 `proxy` 里填本地代理。
- **agent 日志显示 401/403**：token 过期、没给 Contents 写权限，或 token 文件路径不对。
- **agent 日志显示 `[config]`**：cfdata 第一次运行会在 exe 目录生成配置文件并退出，脚本会自动重试一次；如果仍失败，手动跑一次 cfdata 让它生成配置即可。
- **cfdata 报 `flag provided but not defined`**：本地 cfdata 版本太旧，升级到最新 Release 再试（需要支持 `-nsbsourceurl`、`-github`、`-skipgeo`）。
- **cfdata 上传了但 pool 没变**：检查 Action 是否成功、`results.txt` 是否真的被覆盖；只有合格结果才会被上传。

## 8. 文件说明

| 文件 | 作用 |
| --- | --- |
| `shared-ips.txt` | bot 收集的原始 IP，新的在前 |
| `results.txt` | 每次 cfdata 测速后覆盖写入的合格结果 |
| `pool.txt` | 历史累积池（你正在用的文件） |
| `worker/worker.js` | Telegram → GitHub 收集端 |
| `agent/agent.ps1` | 本地增量测速 |
| `agent/agent.config.example.json` | 参数模板 |
| `agent/install-task.ps1` | 注册/删除计划任务 |