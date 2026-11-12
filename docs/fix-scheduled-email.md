# 定时邮件停发的排查与修复（2026-11）

## 2026-11-12 更新：调度恢复了，但仍然晚

推送 `83aba22` 之后，GitHub 的 `schedule` 重新触发：

| 运行 | 事件 | 预定槽位 | 实际创建 | 延迟 | 结果 |
| --- | --- | --- | --- | --- | --- |
| `43146127453` | `schedule` | 2026-11-11 22:17 UTC | 2026-11-12 03:08 UTC | 4 小时 51 分 | success，邮件已送达 |

也就是说：链路健康，定时器也回来了，但**还是会晚近 5 小时**（北京时间 11 点后才收到）。

恢复原因目前有两种可能，现有证据无法区分：

- 平台侧在 11 月上旬修复了 9 月以来积压的 cron 队列；
- 这次是**真实用户提交**（`17862398256` 身份）把仓库重新激活 —— 这一点值得注意，
  因为 `Keep Alive` 工作流每月的提交是 `github-actions[bot]` 用 `GITHUB_TOKEN` 推的，
  这类提交很可能不计入「仓库活动」，这正是它没能救回定时任务的原因。

两种可能指向同一个结论：**`schedule` 不可依赖**。要么接受每天 11 点后才收到，
要么按下面的方案改用外部触发。

另外，2026-11-11 23:38（北京时间）有一次手动 `workflow_dispatch`（`43050339215`）
跑了 36 分钟后被取消，那次没有发信。

## 结论

代码、密钥、SMTP 配置都没有问题。问题出在 **GitHub 的 `on: schedule` 调度器**上：

| 时间点 | 现象 |
| --- | --- |
| 2026-08-20 ~ 08-25 | 每次只比 22:00 UTC 晚 0.3~0.4 小时 |
| 2026-08-26 ~ 08-28 | 突然晚 4.9 / 7.9 / 5.5 小时 |
| 2026-09 | 稳定晚 1.8~2.2 小时 |
| 2026-10-01 ~ 10-08 | 晚 3~4 小时 |
| 2026-10-09 之后 | **0 次运行**，没有任何失败记录 |
| 2026-11-01 | 手动 `Run workflow` 三次（Test / Send emails daily / Keep Alive），全部 success |

判断依据：

- workflow 的 `state` 是 `active`，Actions 页面也没有「因 60 天不活跃被停用」的横幅，
  所以不是 GitHub 的公开仓库 60 天不活跃规则；
- 手动触发每次都成功，说明 Zotero / arXiv / LLM / SMTP 全链路正常；
- 唯一的异常是「根本没有 run 被创建」——这只能发生在调度侧。

## 已做的改动

### `.github/workflows/main.yml`

1. `cron` 从整点 `'0 22 * * *'` 改为 `'17 22 * * *'`（UTC 22:17 = 北京时间 06:17）。
   整点是 GitHub 调度最拥挤的时刻，错开能减少延迟。
2. 新增 `concurrency: send-emails-daily`，防止两个触发源同时拉起时叠加执行。
3. **日志打码**：原来 `cat config/custom.yaml` 会把整份配置打进 Actions 日志，
   而公开仓库的日志任何人都能看。现在用 `sed` 把 `api_key`、`sender_password`、
   `key`、`user_id`、`sender`、`receiver` 的值替换成 `***` 后再输出。

`schedule` 作为兜底保留，主触发改为下面的外部定时器。

### `scripts/`

| 文件 | 作用 |
| --- | --- |
| `setup_dispatch.ps1` | 一次性配置：录入 PAT（加密保存）、校验权限、注册每日计划任务 |
| `dispatch_daily.ps1` | 调用 GitHub API 的 `workflow_dispatch` 触发 workflow；4 小时内已跑过则跳过 |
| `run_dispatch.cmd` | 给 Windows 任务计划程序用的包装脚本 |

## 你还需要做两步

### 1. 生成 PAT

打开 <https://github.com/settings/personal-access-tokens/new>

- Repository access：`Only select repositories` → 只选 `17862398256/zotero-arxiv-daily`
- Permissions：`Actions` = **Read and write**（`Metadata` 会自动带上 Read）
- Expiration：90 天或更久（记得续期）

### 2. 运行配置脚本

在本仓库的 `scripts` 目录下：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_dispatch.ps1
```

脚本会依次：

1. 让你粘贴 token（输入不回显），并校验它能否读到 workflow；
2. 把 token 用 Windows DPAPI 加密后存到 `%USERPROFILE%\.zotero-arxiv-daily\pat.txt`
   （只有当前 Windows 用户能解密，不会进仓库）；
3. 询问是否注册每天 06:30 的计划任务（勾选 `StartWhenAvailable`，开机晚了也会补跑）；
4. 询问是否立刻发一次测试触发。

### 只想手动点一下？

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\dispatch_daily.ps1
```

日志写在 `scripts/logs/dispatch-YYYY-MM.log`。

## 验证

1. 触发后到 <https://github.com/17862398256/zotero-arxiv-daily/actions> 看是否有新的 `workflow_dispatch` 运行；
2. 跑完后确认邮箱能收到；
3. 第二天早上检查 `scripts/logs/` 里的日志，正常应看到
   `Dispatch accepted` 或 `Skip: run ... already started`。

## 已知的边界

- **可能重复发信**：如果 GitHub 自己的 `schedule` 哪天恢复了，且比外部触发晚，就会多跑一次。
  `dispatch_daily.ps1` 只在「外部触发之前」做去重检查，反向覆盖不到；
  实在介意可以把 `main.yml` 里的 `schedule` 整段注释掉。
- **电脑必须开机**：Windows 计划任务只在机器可用时运行。如果经常关机，
  改用云端定时（例如 cron-job.org 建一个每日 POST 任务，把同一段 API 请求填进去）。
- **PAT 过期**：过期后脚本会返回 401，日志里会写 `FAILED: ...`，按同样步骤重新生成即可。
- **`Keep Alive` 工作流**：它本身也依赖 `schedule`，调度挂了它跟着挂，指望它救不了定时任务；
  如果改用外部触发，这个工作流可以停用（公开仓库 60 天不活跃规则只影响 `schedule` 类 workflow）。
