# 「AI」页

> 上半「会话」卡片：哪个 Claude Code / Codex 会话在等审批、等输入、刚跑完，点一行跳回它的终端；下半「用量」卡片：Claude / Codex / Cursor / Antigravity 的配额与今日 / 本周费用。

## 会话

### 数据怎么来

Claude Code 与 Codex 的 hook 调 `Tally.app/Contents/MacOS/tally-hook`（Codex 加 `--provider codex`），它把事件写成 `~/Library/Application Support/Tally/sessions/<session_id>.json`（先写 `.tmp` 再 rename，app 读不到半个文件）；app 用 kqueue（`DispatchSource`）盯目录，不轮询、不起服务端。被拒绝的是「app 起 socket 让 hook 连」（为单向通知养一个服务端）和「读终端标题猜状态」（分不清等审批和等输入，Codex 不设标题）。

只做 Claude Code 和 Codex：只有它们有 hook 机制。Cursor、Antigravity 只有用量。

### 状态文件契约

| 字段 | 类型 | 可空 | 含义 |
|---|---|---|---|
| `session_id` | string | 否 | agent 的 session_id，只放行 `[A-Za-z0-9._-]`（拼进文件名） |
| `provider` | string | 否 | `claude` / `codex`；老文件缺键按 `claude` |
| `pid` | number | 是 | agent 本体进程 pid：从 hook 的父进程沿 `ppid` 最多走 8 层，短名或路径含 `claude` / `codex`、路径含 `/claude/versions/`（Claude Code 的可执行文件叫版本号，短名是 "2.1.263"）、或 node / bun / deno 的参数里带 claude-code / codex 的那个 |
| `term` | string | 是 | hook 环境里的 `TERM_PROGRAM`（`ghostty` / `Apple_Terminal` / `iTerm.app` / `vscode` …），定位按它分派 |
| `tty` | string | 是 | agent 进程的控制终端，如 `ttys003`；没找到进程或没有控制终端为 null |
| `state` | enum | 否 | `running` / `waiting_permission` / `waiting_input` / `done` |
| `cwd` | string | 否 | 会话**启动时**的目录：文件已存在就沿用旧值。hook 收到的 cwd 跟着会话里的 `cd` 走，而定位要的是 shell 所在目录 |
| `title` | string | 是 | 见「标题」；null 表示没读到，不会是空串 |
| `transcript_path` | string | 否 | 原样透传，Codex 没有时写空串 |
| `message` | string | 是 | `Stop` 的 `last_assistant_message` 前 120 个码点；其他事件 null |
| `updated_at` | number | 否 | 毫秒时间戳，只在真正写文件时更新 |
| `model` | string | 是 | 会话在用的模型 id（如 `claude-opus-5`、`gpt-6-astra`）：hook 入参带 `model` 就用它（Codex 带），没有就取 transcript 尾 64 KB 里最后一条带模型名的记录（Claude 回复的 `message.model`，跳过它报错时写的 `<synthetic>`；Codex 的 `turn_context`），再没有沿用旧值；null 是还不知道。Codex 的 rollout 动辄几百 MB、一轮很长时尾巴里没有 `turn_context`，所以它得靠入参 |

可空键永远写出、没有值写 JSON `null`（自定义 `encode(to:)`），读的一方靠键存在判格式版本。

### 事件到状态（`HookDecision`，纯函数）

| 事件 | 条件 | 写入 |
|---|---|---|
| `SessionStart`、`UserPromptSubmit` | 无（Claude 的 `start_reason` 五种都算） | `running` |
| `Notification` | `notification_type == permission_prompt` | `waiting_permission` |
| `Notification` | `idle_prompt` / `elicitation_dialog` / `elicitation_url_dialog` 且现有 `state == running`，且 transcript 尾巴不显示回合已经结束 | `waiting_input` |
| `Notification` | 同上三种但现有状态不是 `running`（含文件不存在），或回合已经结束（见「打断与 API 报错」） | 不写：`done` 之后闲置不算「等我」 |
| `Notification` | 其他类型 | 不写 |
| `PermissionRequest`（只在 Codex 侧注册） | 无 | `waiting_permission` |
| `PostToolUse` | 现有 `state != running`（含文件不存在、坏文件） | `running`：工具跑完就是 agent 在干活。文件不存在是 Tally 装上时会话正跑在长回合中间；`done` 是后台命令或子 agent 回来触发的新回合，没有 `UserPromptSubmit`；等审批必然已过 |
| `PostToolUse` | 现有 `state == running` | 不写：省得每次工具调用都改文件 |
| `Stop` | 无 | `done` |
| `SessionEnd` | 无 | 删文件 |

Claude 侧不用 `PermissionRequest`（返回值语义没文档，`Notification` 的 `permission_prompt` 时机相同且只读）；Codex 没有 `Notification`，只能挂 `PermissionRequest`，hook 不输出任何 stdout 所以不影响审批。Codex 没有 idle 类通知，它的会话只有三态。

hook 的硬约束：永远 `exit 0`（`Stop` 上 exit 2 会阻止 agent 结束回合）；900 ms 自我退出；stdin 不是 JSON、缺 `session_id`、id 含非法字符、事件名不在表内一律不写；现有文件坏了，需要看现有状态的行按「不写」（`Notification` 的等输入三种），其余照写覆盖。实测 `claude -p` 与 `codex exec` 只触发 SessionStart / UserPromptSubmit / SessionEnd，不触发 Stop，`Stop → done` 只能在交互会话里验；Codex 只在启动时读 hooks.json，注册后已开着的 Codex 会话要重开。

### 打断与 API 报错（Claude Code 的 `sessions/<pid>.json` + `TranscriptTitle.turnEnd`）

按 Esc 打断的回合不发 `Stop`（官方文档：用户打断时不跑）；API 报错（限流、配额用完、登录失效、断连）结束的回合发的是 `StopFailure`，也不是 `Stop`。本机 transcript 实测：正常结束 1808 次里 1781 次跟着 Stop hook，打断 59 次、API 报错 47 次一次都没有。状态文件于是停在 `running`（或打断前的等审批 / 等输入）；配额用完那种 Claude Code 连 `idle_prompt` 都不发，会一直「忙」到两小时后变失联。

两个信号，任一个说结束就算结束：

- **Claude Code 自己的 `~/.claude/sessions/<pid>.json`**（没有文档，codenotch 也靠它）：`status` 是 `busy` / `waiting` / `idle`，回合结束那一刻写 `idle`（实测和 Stop hook 写 done 同一时刻，idle 在后；回合开始时 busy 反而先于 UserPromptSubmit hook），打断也写（实测：还没开始输出就按 Esc，transcript 里没标记，status 已是 idle）；等审批是 `waiting`（实测）。`pid` 用状态文件里记的那个，`sessionId` 要对上（pid 会被系统复用）；没有文件或没有 `status`（老版本、桌面版托管的会话）不算。记录是等输入时不看它：elicitation 对话框是回合中途等人，那时写什么没验证过。
- **transcript 尾 64 KB**：从后往前找第一条主链对话记录——`type` 是 `user` / `assistant`，跳过 `isSidechain`（子 agent）和 `isMeta`（Claude Code 注入的提示）；回合结束后追加的 `file-history-snapshot`、`permission-mode`、`system` 之类一律跳过。`user` 且正文以 `[Request interrupted by user` 开头（含「… for tool use]」）→ 打断；`assistant` 且 `isApiErrorMessage == true` → API 报错，正文（如「You've hit your session limit · resets 3pm」）取前 120 码点；别的，或尾巴里一条对话记录都没有 → 没结束。

只看 transcript 不够：普通打断的标记常常不是按 Esc 那一刻写的。实测 52 次里至少 21 次，标记和下一句话时间戳相同、离上一条记录几十到几百秒；还没开始输出就按 Esc 的那次实测，干等 100 秒 transcript 里什么都没多。也就是标记等用户发下一句才补进去，干等的那段只有 status 知道。transcript 这路留着，是为了拿 API 报错那句正文、分辨要不要弹，也给没有 status 的老版本兜底。标记当场写入的，59 次里 58 次是那个回合最后一条对话记录；API 报错 47 次没有一次在同一回合内偷偷重试成功，接着跑的 9 次前面都有新的一条输入（注入的「Continue」、配额重置后自动续、排队的提示、`/login`）。

用在两处：

- **app**：`SessionStore.reload()` 对 `state != done` 的 Claude 会话看这两个信号，结束了就把内存里的记录改成 `done`，**不回写文件**——回写会和 hook 抢：刚判完用户就发了下一句，app 写的 done 会盖掉 hook 写的 running。transcript 说是 API 报错：`message` 是那句报错，照常弹；其余（打断）：`message` 清空、不弹提示（人就在终端前按的键）。文件不变时靠 60 秒一次的重算发现，所以最多晚一分钟。下一句话来了 hook 写 running、Claude Code 写 busy，自然回到「忙」；配额重置后自动续跑的回合没有 `UserPromptSubmit`，status 变回 busy、尾巴上出现新的 assistant 记录，同样回到「忙」。
- **hook**：等输入三种通知在现有状态是 `running` 时先看 transcript 尾巴，回合已结束就不写（`HookDecision.decide` 的 `turnEnded`，只有这一行才读文件）；`idle_prompt` 另外看 status，是 `idle` 也不写——它只在回合结束后一分钟发，文件这时还是 `running` 就是打断或报错没发 Stop，而打断标记常常还没进 transcript。elicitation 两种是回合中途等人，只看 transcript。不拦的话「完成」会变成「等输入」再弹一次。

不注册 `StopFailure`：打断只能靠上面两个信号，API 报错顺带一起判，就不用多改用户的 `settings.json`——2.1.78 之前没有这个事件，2.1.101 之前遇到不认识的事件名会让整份 settings.json 失效；装过 hook 的机器升级 Tally 也不用重新点「安装」；「回复到一半断连」那种报错走不走 `StopFailure` 也确认不了。

Codex 不在内：rollout 格式不同（打断记成 `turn_aborted`），也没有 status 文件，打断时发不发 `Stop` 还没验证。

### 标题（`TranscriptTitle`）

Claude 的 transcript 是 JSONL，标题记录两种：`{"type":"ai-title","aiTitle":…}` 与 `/rename` 的 `{"type":"custom-title","customTitle":…}`，后者还有边车 `<transcript 目录>/<session_id>/custom-title.json`。读法：边车 → 文件尾 64 KB 从后往前找（丢掉首个换行前的半行）→ 都没有为 null。hook 只做前两步；app 在 `title == null` 时再试，仍空就整文件扫一次（每会话只扫一次，结果缓存），还没有就用 cwd 最后一段显示。Codex 不设标题。

### 陈旧、存活、清理（`SessionRecord`，纯函数）

| 条件 | 处理 |
|---|---|
| `pid` 非空且 `kill(pid, 0)` 返回 `ESRCH` | 会话没了（关终端不触发 SessionEnd），读目录时直接删文件 |
| `state != done` 且两小时没更新 | 标「失联」，灰斜体，不删 |
| `state == done` 且两小时没更新 | 照常显示完成 |
| 24 小时没更新 | 启动时和每小时删文件（给没拿到 pid 的孤儿）；活着的会话下一次 UserPromptSubmit 会重建 |

### 提示

`SessionStore.reload()` 每次把上一轮和这一轮的记录按 `session_id` 对比：上一轮见过、这一轮进入了 `done` / `waiting_permission` / `waiting_input` 且和上一轮状态不同的会话，逐个回调 `sessionAlert`，控制器在面板闭合时弹提示（外观、时长、点击跳回见 [panel.md](panel.md) 的「提示」）。第一次露面就已经在那个状态的不算（Tally 晚于会话启动，或刚装上 hook）；`done → running → done` 每个回合都算；审批过了回到 `running` 不弹；打断补判出来的 `done` 不弹（见「打断与 API 报错」）。

### 会话行

按 `updated_at` 倒序：状态图标（等审批橙叹号、等输入黄问号、忙灰虚线圆、完成绿勾、失联灰断线）+ 标题 + 标签 + 目录名 + 距上次事件多久。标签是提供方标志（Claude 橙、OpenAI 白）加模型短名（`SessionRecord.modelLabel`：`claude-opus-5` →「Opus 5」、`claude-fable-5-1` →「Fable 5.1」、`claude-haiku-4-5-20251001` →「Haiku 4.5」，别家原样如「gpt-6-astra」）；还不知道模型时写「Claude」「Codex」。面板展开时 ⌘1–⌘5 跳第 N 行（默认开，设置里可关，见 [panel.md](panel.md)「键盘」）。列表空显示终端图标加「没有在跑的会话」。悬停行有底色。点行走 `TerminalLocator.focus`（经 `SessionJump`），失败在行内显示「找不到窗口」或「<app> 没在跑」；失败原因按会话记在 `SessionJump.failures`，⌘1–⌘5 跳失败时同一行一样显示。

### 跳回终端（`TerminalLocator`）

按 `term` 分派（`kind(for:running:)` 纯函数）：

| `term` | 做法 |
|---|---|
| nil / `ghostty` | AppleScript 枚举 `window → tab → terminal`（id / name / working directory），`focus terminal id`。分隔符在 tell 块外取 `character id 9`：块内写 `tab` 会被 Ghostty 的 `tab` 类遮蔽 |
| `Apple_Terminal` | AppleScript 找 `tty` 相等的 tab，`set selected tab`，窗口置前，块内 `activate` |
| `iTerm.app` | 同上，遍历 `windows → tabs → sessions` 比 `tty`，`select` 会话与窗口，块内 `activate` |

三段脚本都写 `tell application id "<bundle id>"` 而不是按名字：iTerm2 的文件叫 `iTerm.app`、`CFBundleName` 却是 `iTerm2`，按名字找碰上改过名的安装会解析不到，AppleScript 会弹「选择应用程序」或直接报错。`activate` 不在这几个 app 的字典里，但它是 AppleScript 内置词汇，照样能用（实测）。
| `vscode` | VS Code 与 Cursor 都报 vscode，哪个在跑用哪个（`com.microsoft.VSCode` / `com.todesktop.230313mzl4w4u92`）。它们没有能定位到某个终端标签的脚本接口，所以用它打开会话的 `cwd`：编辑器会把那个工程的窗口带到前台，比单纯 `activate()` 接近「跳回这个会话」——而且后台 app 调 `activate()` 常被系统的协作激活规则挡掉，点了没反应 |
| `WarpTerminal` / `kitty` / `WezTerm` | 只激活对应 app |
| 其他 | 「找不到窗口」 |

### 自动化授权

Terminal.app、iTerm2、Ghostty 三条路都是发 Apple Event，macOS 按「哪个 app 控制哪个 app」逐对授权，第一次会弹「Tally 想控制 <终端>」。**拒过一次系统就不再弹**，之后每次点都静默失败——这是「点了打不开」最常见的原因（`~/Library/Application Support/com.apple.TCC/TCC.db` 的 `kTCCServiceAppleEvents` 里那条 `auth_value` 为 0）。

所以 -1743（未授权）不能和「找不到窗口」混在一起：`runAppleScript` 单独把它翻成 `needsAutomationPermission`，会话行显示「要允许 Tally 控制 <终端>」，并直接打开「系统设置 → 隐私与安全性 → 自动化」。在那儿把 Tally 下面对应的开关打开即可；开关已经不在了就 `tccutil reset AppleEvents com.aiden.tally` 让系统重新问。

脚本里在 tell 块内加 `activate`：让目标 app 自己把自己叫到前台。后台 app 调 `NSRunningApplication.activate()` 会被协作激活规则挡掉，只靠它经常是「标签选中了但窗口没到前台」。

Ghostty 的匹配（`GhosttyMatch.pick`）：路径两边都 `resolvingSymlinksInPath` 并去尾斜杠；有标题先按标题（终端名等于标题或以「空格 + 标题」结尾，Claude 的标题格式是「状态符号 空格 会话标题」），多个再按目录挑；没标题或没命中按目录：精确相等优先，否则取目录是 cwd 祖先里最深的；Codex 不起会话标题，它的终端叫「状态符号 空格 目录名」，多候选时用目录名再筛一次；取最前面窗口里的那个。首次跳会弹「Tally 想控制 <终端>」的系统授权。

## 用量条

### 来源与移植

数据层移植自 Atoll 的 `LLMUsage` 模块（GPL-3，清单在 `NOTICE`，15 个文件，标「不改」的除文件头外一字节不动；改过的文件第二行注明改了什么）。不移植 NewAPI 提供方、Atoll 的 Claude 配额客户端（它会回写凭据）和 `LLMUsageManager`（`UsageStore` 新写）。定价表 `pricing.json` 随 app 打包不远程拉；没定价的模型标「+未定价」而不是记 0。

移植改动点：`UsageProvider`（去 Defaults，`ProviderID` 四个 case，`enabledKey` 指向 `Preferences`，`limitLabels` / `stripLabels` / `logoName`，`UsageSnapshot` 加 `limitsStale` / `limitsNote` / `scopedLimits`，`UsageLimit` 加 `isExpired(at:)`）；`JSONLUsageParser`（分块循环加 `autoreleasepool`：上游每块 NSData 与每行 JSON 对象图攒到整轮扫描结束，1 GB 日志冲 2 GB 峰值，加池后 90 MB，`JSONLUsageParserMemoryTests` 用 `phys_footprint` 钉上限；扫描拆成 `scan` + `aggregate(records:)` 并加字节预筛，见下面「日志扫描」；`UsageRecord` 加 `Codable` 供缓存落盘；记账口径三条改动见下面「记账口径」）；`ModelPricingManager`（只读包内 pricing.json）；`CodexQuotaClient`（按 `limit_window_seconds` 分槽，不按 primary / secondary 硬套，否则只有 7 天窗口的账号会被贴成「5 小时」；响应体解不出来时的头部兜底同样按 `x-codex-*-window-minutes` 分槽；请求超时 10 秒）；`ClaudeUsageProvider`（配额走下面的顺序）；`KeychainReader`（删掉 Atoll 的 `updateGenericPassword`，这个 app 永不写钥匙串；`genericPassword` 与 `freshestGenericPassword` 的取值都改走 `/usr/bin/security`，理由见下面 Claude 配额那行与 Cursor 那行）；`CursorTokenStore`（先读 `state.vscdb`，钥匙串兜底；原版先读钥匙串）；`AntigravityUsageProvider`（两条配额按池分，原版把 gemini 的周窗口填进了标「Claude 池」的那条；缺 `quotaInfo` 的模型不算读数；配额摘要里没有认得的 bucket 就接着问下一个端点；云端两个地址都被 401 / 403 拒时报「登录已过期」，原版的空 `catch` 把它吞了，只剩一句笼统的取不到）。

### 日志扫描（`UsageScanCache`）

日志是只追加的，所以不用每轮重扫：按文件记住扫到哪个偏移、解析出的记录留在内存，下一轮只读新增那一段。没变的文件一个字节都不读。

| | 本机实测 |
|---|---|
| 周窗口内要扫的量 | Claude 480 MB / 192 个文件，Codex 更多 |
| 全量扫一遍 | 约 14 秒 |
| 增量（文件没变） | 0.04 秒，读 0 字节 |

三个要点：

- **字节预筛**：一行里既没有 `usage` 也没有 `turn_context`，就既产生不了记录也改不了 Codex 的模型状态，整行跳过，省掉一次 String 构造和一次 JSONSerialization。本机八万行里只有一万多行过得了这关。
- **半行不算数**：文件末尾没有换行的那一行可能还没写完，算进这一轮的结果但不计入偏移，下一轮重读；不然会漏记或重复记。
- **落盘**：`~/Library/Application Support/Tally/scan-cache/{claude,codex}.json`，不落的话每次开 app 都要再全量扫一次。两份加起来七八 MB，所以半小时才写一次、退出时补一次；中间丢的进度下次启动只是多读半小时的新增日志。文件坏了或格式版本对不上就整份作废重扫。文件变短（被截断或换了同名文件）也整份重扫。
- **Codex 的累计值跟着文件走**：Codex 记账是相邻两条 `total_token_usage` 相减（见「记账口径」），所以每个文件扫到哪条的累计值和模型名一样存进缓存，续扫从它接着减。末尾那半行算进这一轮，但不推进累计值和模型名：下一轮会重读这行，推进了的话差值为 0，这条就丢了。

### 记账口径

| 情况 | 怎么算 | 为什么 |
|---|---|---|
| Claude 一条消息写成多行 | 同一个 `message.id + requestId` 只算 `output_tokens` 最大的那行 | Claude Code 按内容块把一条回复写成好几行，每行的 usage 是逐步增长的快照：输入与缓存数各行相同，只有输出往上涨，末行才带 thinking 明细。只认首行的话输出少算三成（本机一周 1882 条多行消息，首行无一例外最小，合计 8.6M 对 12.4M） |
| Claude 缓存写入分两档 | `cache_creation.ephemeral_1h_input_tokens` 按 2 倍 prompt 价，其余写入按表里的 `cache_write`（1.25 倍） | 官方价：5 分钟档 1.25 倍、1 小时档 2 倍；Claude Code 大半写的是 1 小时档（本机一周 28M 对 21M）。`ModelPricing` 是原样移植的文件不动，1 小时那部分在 `aggregate` 里另算 `2 × prompt × 数量` |
| Codex 重复上报 | 同一文件内相邻两条 `token_count` 的 `total_token_usage` 相减；某一项变小按新基线记 0；没有 `total_token_usage` 的老格式才退回 `last_token_usage` | Codex 会把上一轮的 `last_token_usage` 原样再报一次（累计值没动），逐条相加多算约 6%（本机一周 30247 条里 2070 条） |

### 各家数据源

| 提供方 | 用量 | 配额 |
|---|---|---|
| Claude | `~/.claude/projects/**/*.jsonl` | 5 小时 / 7 天两条先读 statusline 缓存 `$TMPDIR/claude-agent-state/rate-limits.json`（有且 600 秒内新鲜才用。这份缓存是用户自己的 statusline 脚本写的——本机是 `~/.claude/bin/statusline.mjs`，Claude Code 本身不写；分享出去的机器上多半没有，配额全靠下面的只读 token）；否则 `ClaudeQuotaReadOnly` 只读 access token：`~/.claude/.credentials.json` 的 `claudeAiOauth.accessToken` 没过期才用，没有或已过期就读钥匙串「Claude Code-credentials*」（新版 Claude Code 只写钥匙串，残留的旧文件里是早过期的 token，先认它就一直报「登录已过期」；钥匙串这条分两段：`SecItemCopyMatching` 只取属性挑出前缀底下最新的那条项——不取数据就不解密、不弹框——再用 `/usr/bin/security find-generic-password -s <完整服务名> -a <账号> -w` 取值。不用 `SecItemCopyMatching` 取数据是因为那要 Tally 自己的 cdhash 在那条项的 `partition_id` 里，而 Claude Code 每 8 小时刷新 token 都用 `security add-generic-password -U` 整条重写、把分区列表清回写入方默认的 `apple-tool:`，第三方授权一起被抹掉，于是每次刷新后都弹一次「Tally 想要访问钥匙串」；`security` 是 Apple 工具，吃的正是那条 `apple-tool:` 授权，所以零弹框。`-s` 是精确匹配，服务名必须传枚举到的完整那个。万一某台机器上这条项没有 `apple-tool:` 授权，`security` 会弹框然后一直等，3 秒砍掉——这轮没配额，但不挂住刷新），`GET https://api.anthropic.com/api/oauth/usage`（头 `anthropic-beta: oauth-2025-04-20`），恰好一次不重试；`expiresAt` 已过或 401 → 「登录已过期，去 Claude Code 跑一轮」并退回陈旧缓存；退回陈旧缓存时，已过重置时间的窗口直接丢掉（隔夜没开 Claude Code，缓存里还是昨天的 92%，而那个窗口早就重置了）。不读 refreshToken、不调刷新接口、不写凭据文件与钥匙串（`KeychainReader` 里没有也不许加写函数）。按模型分的周窗口（`limits` 数组里 `kind == "weekly_scoped"`，名字取 `scope.model.display_name`，如「Fable」）只有接口有、缓存没有，所以缓存新鲜时也每 10 分钟问一次接口专门取它（`ScopedLimitsBox` 节流：取到隔 10 分钟再取，失败只隔 1 分钟——代理偶发 SSL 断连，等十分钟这条就一直不出现；不管成没成都记时间，免得 token 过期后每次刷新都去读凭据）。这一次请求**扔后台**，不挡这一轮快照：1 GB 日志本来就要解析好几秒，再串一个网络往返整行会一直「加载中」；取到之后直接补进已有快照（`UsageStore.applyClaudeScopedLimits`，不重新解析日志），界面立刻多出这一条，不用等下一轮刷新；其余时间沿用上一次的值——这个窗口按周走，差十分钟无所谓；过了它自己的重置时间就不再沿用。请求超时钉 10 秒，代理抽风时不至于卡满默认的 60 秒。顶层那几个 `seven_day_opus` / `seven_day_sonnet` 现在恒为 null，不读 |
| Codex | `<codex 家>/sessions/**/*.jsonl` | `<codex 家>/auth.json`（缺了才读钥匙串「Codex Auth」，取值走 `/usr/bin/security`）→ chatgpt.com 的 wham/usage，超时 10 秒；`tokens.access_token` 只读不刷新（有效期 10 天，`codex` 自己跑一次就会续），401 / 403 时标「登录已过期，去 Codex 跑一轮」——不然界面只是静默少两条，看不出是登录过期还是 Tally 坏了；其余失败（没凭据、网络、5xx、响应变形）不写提示，只留日志。两种失败都沿用上一轮的配额并标「~」（见下面 `UsageStore`） |
| Cursor | 无 | `state.vscdb` 取 token，没有才读钥匙串 `cursor-access-token`（取值走 `/usr/bin/security`，3 秒砍掉：用 `SecItemCopyMatching` 取数据会弹授权框，框挂着时这个调用一直阻塞，整轮刷新跟着卡住、四家全停）→ cursor.com 用量接口；两个模型池，没有重置时间 |
| Antigravity | 无 | 找本地语言服务器进程与端口，调 `RetrieveUserQuotaSummary`；Gemini / Claude 两个池各有 5 小时与周两个窗口（bucket `gemini-5h` / `gemini-weekly` / `3p-5h` / `3p-weekly`），每个池显示剩得少的那个窗口，重置时刻跟着它；只有百分比。摘要里一个认得的 bucket 都没有就接着问下一个端点（IDE 起两个语言服务器，答话的常是第二个）。缺 `quotaInfo` 的模型不算读数，不当用光 |

`UsageStore`：只含已开启的提供方，并发刷新、各自失败各自 `.failure`；60 秒节流（手动也不豁免，被跳过返回 false）；每 5 分钟一次，展开面板也刷；`providersChanged()` 重读开关，新开启的那家立刻单独刷一次，不等下一轮、不吃节流。

- **一轮超过 180 秒不再挡路**：一轮刷新要等四家都回来，某家卡住（比如某个调用在等一个没人点的系统框）会让 `isRefreshing` 一直为真，之后的刷新全被跳过、四家一起停。超过 180 秒就放行下一轮，迟到的结果按轮次号丢掉。
- **临时失败沿用上一轮的配额**：某家这一轮没拿到配额（`.failure`，或成功但两条配额都是 nil）而此前 24 小时内真拿到过，就沿用那次的配额并标「~」，这一轮的提示照常显示（`.failure` 的错误文本当提示）；已过重置时间的窗口不沿用，全都过了就照实显示失败。临时断网、一次 429 不该让配额条消失成一行红字；但沿用超过 30 分钟又没有别的提示时，补一句「配额已 N 分钟没更新」（一小时以上按小时说）——接口改版、登录失效这种一直读不到的，不能只剩个「~」挂 24 小时。`UsageStore.carryOver` 是纯函数。

### 显示

每家一行：左格标志 + 名字（标志同会话行：Claude 橙，OpenAI / Cursor / Antigravity 白；Claude 带套餐徽标）+ 两行「今日 $x · 24.1M」「本周 $y · 312M」（费用后面跟 token 数，输入加输出、输入含缓存读写，1000 进制缩写；`isPercentage` 的 Antigravity 这两行都不画），右边两条配额；Claude 还有按模型分的周窗口时，在这一行下面另起一行、和名字列对齐画出来（标签是模型名如「Fable」，一行放不下三条）（标签 Claude / Codex 是「5 小时」「7 天」，Cursor 是两个模型池，Antigravity 是两个池；nil 不画；整数百分比，陈旧（statusline 缓存过期或沿用上一轮）加「~」；「↻HH:mm」重置时刻，24 小时外「↻M/d HH:mm」；已过重置时间的窗口不画——刷新之前那几分钟也不拿旧百分比充数）。颜色 85% 以上红、60% 以上黄。`.loading` 显示「加载中」，`.failure` 显示错误文本，全关显示「没有开启的提供方」。标题行的 ↻ 在 AI 页刷用量，带「更新于 HH:mm」，60 秒内再点提示两秒「60 秒内刚刷过」。

## 验证

```bash
swift test --filter 'HookDecisionTests|HookRunnerTests|SessionModelTests|TranscriptTitleTests|GhosttyMatchTests|TerminalLocatorTests|ClaudeQuotaReadOnlyTests|ClaudeTokenBoxTests|ClaudeLimitsCacheTests|UsageStoreTests|UsageScanCacheTests|JSONLUsageParserTests|JSONLUsageParserMemoryTests|CodexQuotaWindowTests|AntigravityParsingTests|KeychainReaderTests|TokenFormatTests'
export TALLY_SESSIONS_DIR=$(mktemp -d)
echo '{"session_id":"t1","hook_event_name":"SessionStart","cwd":"/tmp"}' | /Applications/Tally.app/Contents/MacOS/tally-hook && cat "$TALLY_SESSIONS_DIR/t1.json"
echo '{"session_id":"t1","hook_event_name":"SessionEnd"}' | /Applications/Tally.app/Contents/MacOS/tally-hook && test ! -f "$TALLY_SESSIONS_DIR/t1.json" && echo GONE
test $(grep -rcE 'SecItemUpdate|SecItemAdd|oauth/token' Sources/ | awk -F: '{s+=$2} END {print s}') -eq 0 && echo CLEAN
```

用例：分派六条（含 vscode 按谁在跑挑 VS Code / Cursor）、-1743 翻成需要授权而不是找不到窗口；增量扫描（文件没变读 0 字节、追加只读新增那段、结果和全量一致、截断后重扫、半行不重复计、重开 app 走盘上缓存、坏缓存丢掉重扫、预筛保住 Codex 模型状态行、Codex 累计值跨增量扫描与重开 app 接得上、末尾半行不推进累计值）；记账口径（Claude 同键多行取最大输出、1 小时档写入按 2 倍 prompt 计价且没定价不凑数、Codex 重复上报不重复记、老格式退回 last_token_usage）；配额（已过重置时间的窗口在陈旧兜底与新鲜缓存里都丢；临时失败沿用 24 小时内的真实读数并标「~」、沿用超过 30 分钟补一句多久没更新、全都重置或太老照实报失败；一轮卡住 180 秒后放行、迟到结果不许覆盖；新开启的一家立刻单独刷）；Antigravity（两条各是一个池、没有认得的 bucket 不算读数、缺 quotaInfo 不当用光、没用过的池是 0%）；token 缩写舍入进位不出「1000k」；`weekly_scoped` 解析出模型名与百分比、顶层 null 字段不当数据；缓存新鲜且 scoped 没过节流窗时不碰接口；映射表每行一个；hook 守门四条；回合结束判定（打断两种写法与之后追加的快照记录、正文是字符串的写法、API 报错取正文、打断后又发了一句 / 报错后排队的输入接着跑不算、尾巴里没有对话记录不算、子 agent 与注入提示跳过）；打断与 API 报错（hook：之后的 idle_prompt 不写、Claude Code status 为 idle 时 idle_prompt 不写而 elicitation 照写、status 对不上会话时照写；app：打断补判成 done 不弹且下一句话回到 running、API 报错补判成 done 弹且带报错、status 为 idle 时没有打断标记也补判、status 是 waiting 或 sessionId 对不上或记录是等输入不算、Codex 与已是 done 的不动）；模型（入参带 `model` 就写、没有从 transcript 尾取、再没有沿用旧值；尾巴里跳过 `<synthetic>`、认 Codex 的 `turn_context`；短名换算）；陈旧 / 存活 / 清理三条；提示判定六条（进入 done 算、进入等审批 / 等输入算、首见即在该状态不算、同状态不重复、每回合都算、打断补判的 done 不算）；标题三种来源；Ghostty 匹配五条；`kind` 六条；只读配额（过期不发请求、200 解析、401 恰好一次请求、凭据文件哈希前后一致、残留的过期凭据文件让位给钥匙串）；解析器内存上限。端到端：在交互会话里发一句话，回合结束后目录里该会话 `"state":"done"`；截图用量四行齐全、Claude 的百分比与缓存文件一致。
