<div align="center">

<img src="docs/images/icon.png" width="112" alt="Tally 图标">

# Tally

**把 Claude Code / Codex 的会话状态和 AI 配额放进 MacBook 刘海**<br>
谁在等你、谁跑完了、额度还剩多少，鼠标一停就知道。

简体中文 | [English](README.en.md)

<a href="https://github.com/Aiden-Guokuaile/tally/releases/latest/download/Tally.dmg"><img src="docs/images/download-zh.svg" width="240" alt="下载 Tally（macOS 版）"></a>

或者用 Homebrew 装（免放行）：`brew install --cask aiden-guokuaile/tally/tally`

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black) ![License GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)

<img src="docs/images/hero.gif" width="820" alt="会话跑完时刘海垂下提示，鼠标停上去展开面板，在 AI、网络、系统几页之间切换">

</div>

同时开着几个 agent 会话，得不停切窗口看谁在等审批、谁跑完了；配额快见底了也不知道。Tally 把这些收进刘海：平时和刘海融为一体，有事才往下垂一条提示；鼠标停上去就展开成一整块面板。

## 为什么用 Tally

- **谁在等你，一眼看清**：Claude Code 和 Codex 的会话按「等你 / 在跑 / 最近」分组；等审批、等输入、跑完了，刘海垂一条提示并响一声。
- **状态判得准**：按 Esc 打断、API 报错、主回合结束后子 agent 还在后台跑，这些 hook 不报的情况也判得对，不会一直挂着「忙」。
- **一下回到那个终端**：点一行（或 ⌘1–⌘9、⌘0）直接跳到会话所在的终端标签，tmux 的 pane 也行；关掉的会话点「接着聊」开个新窗口接着聊。
- **各家额度摆一排**：Claude、Codex、Cursor、Antigravity，加上 DeepSeek、Kimi、智谱 GLM、New API 中转站；Claude 和 Codex 还有今日 / 本周花费和配速线，照这个速度会不会在重置前用完一眼能看出，过 80% 和用完都会提醒。
- **本地、原生、零依赖**：SwiftUI + AppKit，只读各家登录留下的 token（不刷新、不往钥匙串写），没有统计上报。

顺手还带着：网速与代理、内存与电池、在跑的 app、文件架、保持唤醒（含合盖不休眠），和一只可选的菜单栏小恐龙。

## 五个页面

<table>
  <tr>
    <td width="50%"><img src="docs/images/ai.png" alt="AI 页：会话列表与各家用量"><br><b>AI</b>：会话列表 + 各家用量条</td>
    <td width="50%"><img src="docs/images/network.png" alt="网络页：吞吐、Wi-Fi、IP 与 DNS"><br><b>网络</b>：吞吐、Wi-Fi、IP、DNS</td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/system.png" alt="系统页：CPU、内存、电池与废纸篓"><br><b>系统</b>：CPU、内存、电池、废纸篓</td>
    <td width="50%"><img src="docs/images/apps.png" alt="应用页：在跑的 app 按内存排"><br><b>应用</b>：在跑的 app 按内存排</td>
  </tr>
</table>

- **AI**：会话行带提供方标志和模型名。会话跑完或在等你时，刘海垂一条提示并响一声；面板开着时不提示，会话所在的 Ghostty / Terminal.app / iTerm2 标签正在前台时也不打扰；合盖只剩外接屏时改发系统通知。
- **网络**：网卡吞吐（最近 60 秒折线）、Wi-Fi 信号、本机 IP、网关、DNS；开着系统代理或代理软件时多一张卡片，认出是哪个代理 app、端口、有没有 TUN（接了 mihomo 内核的控制接口时还显示模式）。
- **系统**：芯片、内存、CPU、磁盘、开机时长，电池健康，内存大户前三，废纸篓大小与一键清空。
- **应用**：在跑的 app 按内存排，Dock 里看不见的菜单栏工具和后台 app 带标记，点行打开，右键退出。
- **文件架**：把文件拖到刘海上暂存一份副本（脚本里 `open -a Tally <文件>`、新截图也能自动放进来），之后拖出去、AirDrop 或打开；到了保留时间自动清掉（文件默认 1 天，截图默认 30 分钟，设置里可调）。

<p align="center"><img src="docs/images/shelf.png" width="600" alt="文件架页：拖到刘海上的文件与截图"></p>

悬停展开、快捷键、文件架、提示音、配额提醒、各家用量都能在设置里单独关掉；「全屏 app 时隐藏面板」「新截图自动放进文件架」默认关，要用在设置里打开。

## 菜单栏小恐龙

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/stride-dark.png">
    <img src="docs/images/stride-light.png" width="560" alt="菜单栏小恐龙的睡觉、跑步、冲刺、生气四个状态，旁边的蛋显示内存">
  </picture>
  <br><sub>睡觉 · 跑步 · 冲刺（蛋过 70% 变橙） · 生气（蛋过 85% 变红裂开）</sub>
</p>

设置「面板」里打开（默认关）。恐龙跟着 CPU 睡觉、跑步、冲刺，内存吃紧就冲刺、生气；身边一颗窝里的蛋按内存已用填满，70% 变橙、85% 变红裂开。点它展开面板到「系统」页。

## 安装

**Homebrew**（推荐，装完不用再放行）：

```bash
brew install --cask aiden-guokuaile/tally/tally
```

**或者下载 DMG**：

1. 下载 [Tally.dmg](https://github.com/Aiden-Guokuaile/tally/releases/latest/download/Tally.dmg)，把 Tally 拖进「应用程序」。
2. 在终端放行一次，再从「应用程序」里打开：

   ```bash
   xattr -dr com.apple.quarantine /Applications/Tally.app
   ```

> [!IMPORTANT]
> Tally 是个人项目，没有 Apple 开发者签名和公证，macOS 默认会拦下来，所以要有第 2 步。不想敲命令的话，先双击打开一次，被拦下后去「系统设置 → 隐私与安全性」最下面点「仍要打开」。提示「已损坏，无法打开」是同一回事，执行上面那条命令即可。

一定从「应用程序」里打开。直接在 DMG 或下载文件夹里运行时，系统会把 app 挪到临时位置，这时设置里不让注册 hook（那个路径重启就失效）。

**系统要求**：macOS 15 及以上、Apple Silicon、带刘海的 MacBook（2021 年起的 14 / 16 英寸 MacBook Pro、M2 及以后的 MacBook Air）；界面为简体中文。别的 Mac 能启动，但面板不会出现（提醒改发系统通知）。

## 接上 Claude Code 和 Codex

打开设置（面板右上角齿轮，或展开时按 ⌘,）→「hook」→ 两边各点一次「安装」。

- Claude 侧改 `~/.claude/settings.json`，Codex 侧改 `~/.codex/hooks.json` 和 `~/.codex/config.toml`（写入信任哈希）；改之前都备份成 `.tally-backup`，你原有的 hook 不动。设置过 `CLAUDE_CONFIG_DIR` / `CODEX_HOME` 的会装到那里，用量和配额也跟着读那里。
- Codex 侧安装要用到本机的 `codex` 命令。
- 装之前就开着的会话要重开一次才会挂上，Codex 只在启动时读 hook。
- 装好后每一侧下面显示「最近收到事件」；一直显示「还没收到过」时点「自检」，能看出是 hook 本身跑不起来，还是 agent 没在调它。

## 支持哪些

| Agent | 会话状态 | 跳回终端 | 接着聊 |
|---|---|---|---|
| Claude Code | ✓ | ✓ | `claude --resume` |
| Codex | ✓ | ✓ | `codex resume` |

| 用量 | 配额 | 花费 / 余额 |
|---|---|---|
| Claude | 5 小时、7 天、按模型的周窗口（带配速线） | 今日 / 本周花费 |
| Codex | 5 小时、7 天（带配速线） | 今日 / 本周花费 |
| Cursor | 「Cursor 模型」「其他模型」两个池 | — |
| Antigravity | Gemini、Claude 两个池 | — |
| DeepSeek | — | 余额 |
| Kimi | Kimi Code 会员 5 小时、7 天（带配速线） | 开放平台余额 |
| 智谱 GLM Coding Plan | 5 小时、7 天（带配速线） | — |
| New API 中转站 | — | 余额 |

后四家默认关，在设置「用量」里打开。key 先从 Claude Code 设置、Kimi Code、zcode、opencode 里自动找，找不到再手填；智谱的配额接口没有公开文档，改版可能失效。

<details>
<summary><b>点会话行能跳到哪些终端</b></summary>

| 终端 | 点会话行 |
|---|---|
| Ghostty、Terminal.app、iTerm2 | 切到那个会话所在的标签 |
| tmux | 切到那个 pane；外层是 Terminal.app / iTerm2 时连标签一起切，别的终端带到前台 |
| VS Code、Cursor | 打开会话所在的工程窗口 |
| Warp、kitty、WezTerm | 只把 app 叫到前台（没有稳定的脚本接口） |

表外的终端点了会提示找不到窗口。「接着聊」回到会话原来的终端开新窗口（Ghostty、Terminal.app、iTerm2；tmux 里开一个新的 tmux 窗口），其余情况装了 Ghostty 用 Ghostty，没装用 Terminal.app。

</details>

## 快捷操作

| 操作 | 效果 |
|---|---|
| 鼠标停在刘海上 / 移开 | 展开 / 收起 |
| ⌥⇧T | 展开并钉住 / 收起 |
| 两指横滑、三指轻扫、数字键 1–9 | 翻页 |
| ⌘1–⌘9、⌘0 | 跳到第 N 个会话（⌘0 是第 10 个），按住 ⌘ 显示编号 |
| 齿轮、展开时按 ⌘, | 设置 |
| 右键收起的刘海 | 菜单：设置、刷新用量、退出 |

## 权限与隐私

**用到时才会问的权限**

- **自动化（控制终端）**：跳回终端、接着聊、判断会话标签是否在前台。第一次控制某个终端时系统问一次。
- **管理员密码**：只跟「合盖也不休眠」有关。第一次打开时装一条 `/etc/sudoers.d/tally` 免密规则，只放行开 / 关休眠的两条 `pmset` 和删掉这条规则自己；另外，启动时发现合盖不休眠开着、又不是 Tally 开的，会给一个「恢复」按钮，点它要输一次密码。
- **钥匙串**：各家登录凭据只读，取值走系统自带的 `security` 工具，平时不弹框。Codex、Cursor、Antigravity 平时读本地文件或本地服务，钥匙串只作兜底。
- **通知**：只在没有刘海屏（合盖接外接屏）、第一次要发提醒时问。
- **文件夹访问**：打开「新截图自动放进文件架」时，在选择面板里点一下截图文件夹；桌面受隐私保护，点这一下就是授权，不另弹框。

**不会申请**：屏幕录制、摄像头、麦克风（占用提示只读设备状态）、辅助功能、定位、完全磁盘访问。

**数据**：会话、日志统计、设置都留在本机，没有统计上报，也没有自动更新。对外联网只有两件事：向各家官方接口查配额和余额（Anthropic、OpenAI（ChatGPT）、Cursor、Google（Antigravity），以及打开了才连的 DeepSeek、Kimi / Moonshot、智谱 / Z.ai 和你填的 New API 站点；不想连哪家就在设置「用量」里关掉）；手填的 key 只存在本机 `~/Library/Application Support/Tally/providers.json`（权限 600）；每天问一次 GitHub 有没有新版本（设置「通用」里可关，只提示，不自动下载替换）。

## 常见问题

- **面板不出现**：只在带刘海的内建屏上显示；合盖或只用外接显示器时会隐藏（提醒改发系统通知）。开了「全屏 app 时隐藏面板」的话，全屏 app 里也不出现。
- **全屏看视频时不想看到刘海面板**：设置「面板」打开「全屏 app 时隐藏面板」。只认系统全屏（绿色按钮、⌃⌘F）。
- **提示「已损坏」或「无法验证开发者」**：见「安装」第 2 步。
- **会话列表是空的**：先到设置「hook」看是不是已安装、有没有「最近收到事件」；装之前开着的会话要重开；还不行就点「自检」。
- **点会话行提示「要允许 Tally 控制 ××」**：去「系统设置 → 隐私与安全性 → 自动化」，打开 Tally 下面对应的开关。找不到开关时执行 `tccutil reset AppleEvents com.aiden.tally`，再点一次让系统重新问。
- **只把终端叫到前台、没切到那个标签**：Warp、kitty、WezTerm 没有稳定的脚本接口，只能做到这一步。
- **配额显示「登录已过期」**：去 Claude Code 或 Codex 里跑一轮，让它自己刷新登录。Tally 不刷新 token。
- **百分比后面带「~」**：这一轮没取到新读数，显示的是之前的值。

## 卸载

1. 设置「hook」里两边各点「移除」，只删 Tally 自己的那几条。
2. 开过「开机自启」的，先在设置「通用」里关掉；开过「合盖也不休眠」的，在设置「面板」里取消「合盖不休眠的免密规则」。
3. 退出 Tally，把 `Tally.app` 拖进废纸篓。
4. 想清干净，再删 `~/Library/Application Support/Tally/`。

用 Homebrew 装的：第 1 步照做，第 3、4 步换成 `brew uninstall --zap --cask tally`（连数据目录和开机自启一起清）。

<details>
<summary><b>工作原理</b></summary>

```
Claude Code / Codex ──hook──▶ tally-hook ──▶ ~/Library/Application Support/Tally/sessions/<id>.json ──▶ 刘海面板
                                                                                            ▲
                                        transcript、Claude Code 自己的会话状态（补判打断与报错）
```

hook 只往本地写两样东西：会话状态文件，和一份「最近收到的事件」（给自检用），写完立即退出，从不拦 agent。面板盯着会话目录更新；hook 报不出来的情况（打断、报错），再读 transcript 和 Claude Code 自己的状态补判。配额来自本地日志和各家接口。设计细节见 [docs/](docs/README.md)，参与开发见 [CONTRIBUTING.md](CONTRIBUTING.md)。

</details>

## 致谢

- [Atoll](https://github.com/Ebullioscopic/Atoll)：用量数据层移植自它（GPL-3.0），文件清单见 [NOTICE](NOTICE)。
- [NotchDrop](https://github.com/Lakr233/NotchDrop)：文件架的交互参考了它，代码是重写的。
- [Lobe Icons](https://github.com/lobehub/lobe-icons)：提供方标志（MIT），取自 [Pulse](https://github.com/qunqin24/Pulse) 整理的版本。
- 借鉴过的做法：[vibe-notch](https://github.com/farouqaldori/vibe-notch) 与 [CodeIsland](https://github.com/wxtsky/CodeIsland)（终端标签在前台时不提示）、[codenotch](https://github.com/vinzdg/codenotch)（读 Claude Code 自己的会话状态、429 退避）、[codex-island](https://github.com/ericjypark/codex-island)（睡醒后缓一分钟再查配额）。

## 许可

[GPL-3.0](LICENSE)。Claude、OpenAI、Codex、Cursor、Antigravity 的名称与标志归各自所有者，Tally 只用它们标明是哪家的会话与用量；Tally 是个人项目，与 Anthropic、OpenAI、Anysphere、Google 均无关联。

---

<p align="center">觉得 Tally 好用的话，点个 ⭐ Star，让更多同样开着一堆 agent 的人看到它。</p>
