# hook 的注册、移除与分享

> 会话数据靠 hook 注册（Claude Code 七条、Codex 六条）；设置窗口的「安装」「移除」按钮改的是用户自己的配置文件，改前留备份。

## 注册什么

Claude 侧 Claude 的家（默认 `~/.claude`，见「安装」）里 `settings.json` 的七个事件 `SessionStart`、`UserPromptSubmit`、`Notification`、`PostToolUse`、`PreCompact`、`Stop`、`SessionEnd` 各一条（`PreCompact` 很早就有，碰不上「老版本 Claude Code 不认识事件名、整份 settings.json 失效」那个坑；装过旧版 Tally 的机器升级后，设置里会显示「PreCompact 未注册」，点一次「安装」即可）：

```json
{ "hooks": [ { "type": "command", "command": "\"/Applications/Tally.app/Contents/MacOS/tally-hook\"", "timeout": 5 } ] }
```

Codex 侧 codex 家目录下 `hooks.json` 的六个事件 `SessionStart`、`UserPromptSubmit`、`PermissionRequest`、`PostToolUse`、`Stop`、`SessionEnd` 各一条，命令后加 ` --provider codex`。路径带双引号，防 app 被放到带空格的目录。Codex 对每条 hook 算哈希存在同一个家的 `config.toml` 的 `[hooks.state."<hooks.json 路径>:<事件>:<组序号>:<hook 序号>"]`，没写 `trusted_hash` 的不执行。

## 安装（`HookInstaller.install`，幂等）

codex 的家默认 `~/.codex`，但 `CODEX_HOME` 能指到别处——有人给终端 codex 单开一个家，好跟 ChatGPT 桌面版共用的那份隔开。所以家目录由 `CodexHome` 统一定：先看 app 自己的环境（从终端启动时才有），再问一次登录 shell（`echo TALLY_CODEX_HOME=$CODEX_HOME`，实测 10 ms，一个进程只问一次），都没有才 `~/.codex`。问 shell 有 10 秒上限（`LoginShell.lines` 走 `Subprocess.run`）：这一步在启动路径上，某台机器的启动脚本卡住、或起了个后台进程一直占着 stdout，都不能把刘海挂得出不来——到点就用已经收到的输出，里面没有要的那行就按问不到处理。hook 装哪儿、用量读哪儿（`~/<家>/sessions`）、配额读谁的 `auth.json`，全跟着它走；装错家等于装了也收不到会话。跑 app-server 时也要把 `CODEX_HOME` 传给子进程，否则它按默认家算哈希，跟我们刚写的那份 hooks.json 对不上。

Claude 侧同理（`ClaudeHome`）：`CLAUDE_CONFIG_DIR` 设了，Claude Code 的 settings.json、projects/、sessions/、.credentials.json、.claude.json 整个搬到那个目录，hook 就装进那里的 settings.json。问法和 `CodexHome` 一样（app 自己的环境 → 登录 shell 的 `echo TALLY_CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR` → `~/.claude`）。hook 进程从 Claude Code 继承环境，读 Claude Code 自己的 `sessions/` 时直接看 `CLAUDE_CONFIG_DIR`。只认一个家：几个账号各开一个目录同时用的话，Tally 跟着登录 shell 里设的那个。


- 「Tally 匹配组」= 只含一个 hook 且命令含 `tally-hook`（或旧版的 `claude-event.js`）的匹配组。每个事件下：有就**原位**替换成期望组（多个时第一个原位、其余删），没有才追加到末尾。原位是因为 Codex 的信任键含序号，删了再追加会让别的 hook 序号漂移、哈希失效。
- 文件不存在或 0 字节按 `{}`；不是合法 JSON 对象就抛错不覆盖。写回 `JSONSerialization` 的 prettyPrinted + sortedKeys + withoutEscapingSlashes，键会按字母序重排一次。
- Codex 侧写完再跑 `codex app-server` 的 `initialize` + `hooks/list`，取命令含 `tally-hook` 的条目的 `key` 与 `currentHash`，在 `config.toml` 里同键就地改写 `trusted_hash`、没有才追加整块。哈希那步失败就用备份把 hooks.json 退回去再报错，不留半套。

  找 `codex` 分三级，命中即停：登录 shell（`$SHELL -lc`，`$SHELL` 没有就 `/bin/zsh`）→ 交互登录 shell（`-ilc`）→ 常见安装目录（homebrew 两处、`~/.local/bin`、`~/.bun/bin`、`~/.cargo/bin`、`~/.npm-global/bin`、`~/.volta/bin`）。app 自己只有 launchd 给的那几个系统目录，所以必须问 shell；而**登录 shell 不读 `.zshrc`**（zsh 只在交互时读它），nvm、volta、改过 npm prefix 的机器把 PATH 写在那儿。每次问 shell 的命令是 `command -v codex; echo TALLY_PATH=$PATH`，一次拿两样：路径按行挑真能执行的那条（交互 shell 会吐主题、instant prompt 那类噪声；`codex` 被包成 shell 函数时 `command -v` 只回名字，正好一起滤掉），PATH 认 `TALLY_PATH=` 前缀。

  起 app-server 时子进程的 PATH = codex 所在目录 + 上面那步拿到的 shell PATH + app 自己的 PATH。codex 常是 `#!/usr/bin/env node` 的脚本，app 的 PATH 里没有 node，直接跑得到的是 `env: node: No such file or directory`，界面上却显示「没拿到信任哈希」；node 也不一定和 codex 同目录（实测有台机器 codex 在 `~/.local/bin`、node 在 `/usr/local/bin`），所以只补 codex 那层目录不够。

  读 app-server 的输出是**边跑边读、读到 id 为 2 的那条就停**（上限 20 秒）。子进程统一走 `Subprocess.run`，上限对每条路径都生效：stdout 与 stderr 同时收（stderr 灌满 64 KB 管道也堵不住），等输出、等退出都按同一个截止时间，到点先 SIGTERM，1 秒后还在就 SIGKILL。原来是循环里调 `availableData`，它在管道没数据时一直阻塞，截止时间只在两次读之间检查——app-server 一声不吭就永远卡住，「安装」按钮一直转、`--install-hooks` 不退出（探针：上限 2 秒、子进程 6 秒不出声，照样等满 6 秒）。原先是「睡 4 秒 → 关 stdin → 等它退出 → 一次性读」，两头都会坏：慢机器上 4 秒还没答完就被 terminate；hook 多的机器输出超过管道缓冲（64 KB）会把 app-server 堵死，再 terminate 读到的是半截——两种都表现为「响应里没有 id 为 2 的结果」，而那句话对排查毫无帮助。现在 id 为 2 那条带 `error` 时把它的原话报出来（比如「不支持 hooks/list」），失败时还附上 stderr 与收到的开头一段。本机实测 0.1 秒拿到 11 条。
- 改前复制成 `<原名>.tally-backup`；失败时界面显示原因和一份可复制的手工步骤。
- 状态 `installed`（每个事件都恰好一个 Tally 组且命令等于期望）/ `pointsElsewhere(说明)` / `missing`。`Tally --install-hooks` 是同一逻辑的命令行入口。

不做「首次启动自动注册」：改别人的配置必须是用户点了按钮。

**不在固定位置就不给装**（`BundleLocation.isUnstable`）：从 DMG 或下载目录直接打开时，Gatekeeper 会把 app 搬到 `/private/var/folders/…/AppTranslocation/<UUID>/d/Tally.app` 跑，这个路径重启就没了。写进两边配置的 hook 命令是绝对路径，写进去等于埋一个「重启后 agent 调不存在的文件」。所以路径里带 `/AppTranslocation/` 或以 `/Volumes/` 开头时直接报错，让用户先把 app 拖进「应用程序」。

## 移除（`HookInstaller.uninstall`）

删掉各事件下的 Tally 匹配组，别的 hook 不动；事件数组空了连键一起删，`hooks` 空了连顶层键一起删；照样留备份。Codex 侧删掉后别的 hook 序号前移，所以改之前先跑一次 `hooks/list` 记下哪些命令是 `trustStatus == trusted` 的，改完再跑一次，只把这些按新键写回 `config.toml`，用户没信任过的一条不碰；后半步失败就把 JSON 退回备份。Tally 自己那几条 `[hooks.state.…]` 留着不清，键已没人引用，无害。

卸载 Tally = 设置里点两个「移除」，再把 Tally.app 拖进废纸篓。macOS 不让 app 在被删除时自己跑清理，所以分两步。

## 自检（设置 → hook）

每侧 hook 行下面两样东西，专治「装了没反应」（同类项目公开后评论最多的就是这一类）：

- **最近收到事件**：`tally-hook` 每收到一个合法事件（session_id 和事件名都校验过），就把事件名和时间写进 `~/Library/Application Support/Tally/hook-last-<claude|codex>.json`（`HookHeartbeat`）。放在会话目录的上一层：会话目录被 kqueue 盯着，写在里面的话每次工具调用都会让 app 重读一遍目录。设置页读它显示「最近收到事件：3 分钟前（Stop）」；从来没收到过显示「还没收到过事件」——多半是装之前就开着的会话没重开（Codex 只在启动时读 hooks.json），Codex 侧还可能是信任哈希没写上。写这个文件失败不影响记状态，hook 照样 exit 0。
- **自检按钮**（`HookSelfTest`）：状态不是「已安装」就不跑，提示先点「安装」——配置里不是这条命令的话，二进制跑通了也证明不了 agent 调得通。装好了就把写进配置的那条命令（带引号的路径，Codex 侧跟 `--provider codex`）原样交给 `/bin/sh`（前面加 `exec`，被信号杀掉才看得出来），喂一条模拟的 `SessionStart`，`TALLY_SESSIONS_DIR` 指到临时目录，3 秒截止。stdin 走 `/bin/sh` 的文件重定向：hook 要把 stdin 读到结束，`Subprocess.run` 给的管道一直开着，直接喂的话 hook 会等到 900 ms 自退、什么都不写。结果一句话：正常（多少 ms、写出了状态文件）/ 退出码非 0（带 stderr 开头）/ 被信号杀掉（常见于 app 被系统隔离）/ 跑完没写出文件（目录没有写权限）/ 3 秒没退出。它分得清「hook 本身坏了」和「agent 没调它」，后一种看上面那条。

## 发版与更新

发版（脚本只留在维护者本地）一次做完：编 app → 打 DMG → 以 `Tally.dmg` 为名传到公开仓库的 Release（tag `v<CFBundleShortVersionString>`，打在公开仓库 main 最新的提交上，所以先让公开仓库是这次要发的代码）→ 算 sha256，写进 `guokuaile/homebrew-tally` 的 `Casks/tally.rb` 推上去（仓库不存在就建）。版本号三段式；同一个 tag 发过就报错退出。

- **资源名固定 `Tally.dmg`**：README 的下载按钮指着 `releases/latest/download/Tally.dmg`，GitHub 按资源名 302 到最新那个 Release。cask 的 url 却按 tag 钉死：指 latest 的话，下一次发版 sha256 就对不上。
- **cask 装完清隔离标记**（`postflight_steps` 跑 `xattr -dr com.apple.quarantine`）：DMG 是 ad-hoc 签名、没公证，不清的话每次装、每次升级都要去系统设置点「仍要打开」（macOS 15 起右键打开那条路没了）。Homebrew 官方仓库不收这样的 cask（要求过 Gatekeeper），第三方 tap 可以，boring.notch 同样这么做；`--no-quarantine` 参数 Homebrew 6 起已经没有。
- **开机自启放 `zap` 不放 `uninstall`**：`brew upgrade` 也会跑 `uninstall`，放那儿每次升级都会把 LaunchAgent 删掉。hook 注册 Homebrew 管不到（改的是用户自己的配置文件），caveats 里提醒先在设置里点「移除」。

DMG 本身：Tally.app + Applications 快捷方式 + 「首次打开必读.txt」，强制重签成 ad-hoc（理由见 [panel.md](panel.md)「打包与安装」）。装好后在设置里点两个「安装」；首次点会话行弹终端自动化授权；查配额不弹钥匙串框（取值走 `/usr/bin/security`，理由见 `ai.md`）。GPL-3：发 DMG 的同时源码要能拿到，仓库公开即可。

**新版本提示**（`UpdateChecker`，设置「通用 → 检查新版本」，默认开）：启动时和之后每 24 小时 `GET https://api.github.com/repos/guokuaile/tally/releases/latest`（不带 token，匿名额度一小时 60 次，远用不完），`tag_name` 去掉开头的 `v` 和 `-` / `+` 后缀、按点拆成整数补零逐段比，比 `CFBundleShortVersionString` 新就在设置「通用」显示一行、刘海垂一条「有新版本」（同一个版本只垂一次，记在 `Preferences.updateNotifiedVersion`）。有 `/opt/homebrew/Caskroom/tally`（或 `/usr/local/…`）就说 `brew upgrade --cask tally`，否则给 Release 页的「去下载」。404（还没发过版）不算失败；403 / 429 说限流；别的失败原因显示在设置里。只提示不替换：DMG 是 ad-hoc 签名，下载下来验不了真假，自动换掉等于替人跑一个没法验证的程序。

## 验证

```bash
swift test --filter 'HookInstallerTests|HookSelfCheckTests|UpdateCheckerTests'
/Applications/Tally.app/Contents/MacOS/Tally --install-hooks
H='"/Applications/Tally.app/Contents/MacOS/tally-hook"'
jq --arg c "$H" '[.hooks | to_entries[] | .value[] | .hooks[] | select(.command == $c)] | length' ~/.claude/settings.json
jq --arg c "$H --provider codex" '[.hooks | to_entries[] | .value[] | .hooks[] | select(.command == $c)] | length' ~/.codex/hooks.json
curl -sLo /tmp/Tally.dmg https://github.com/guokuaile/tally/releases/latest/download/Tally.dmg && hdiutil verify /tmp/Tally.dmg
```

用例：文件不存在 / 0 字节 / 非法 JSON（抛错不覆盖）、别的 hook 保留且序号不变、安装两次相同、旧组原位替换、缺事件报 `pointsElsewhere`、Codex 哈希就地改写、备份存在、移除只删 Tally 组并删空键、移除只重写原本信任的、哈希失败回滚 JSON；心跳（合法事件写、校验不过不写、写在会话目录上一层）、最近收到事件的文案（没收到过 / 刚刚 / 分钟 / 小时 / 天）、自检结果五种文案、没装好不跑、拿编出来的 hook 按配置里的命令格式真跑一次自检。Claude 那条 `jq` 打印 7，Codex 那条打印 6。新版本（补零比较、后缀去掉、认不出的版本号不提示、解析 Release、Homebrew 判定、提示条同一版本同一个 id）。真发一次版才算验过：Release 页有 `Tally.dmg`、`curl -sI https://github.com/guokuaile/tally/releases/latest/download/Tally.dmg` 是 302、tap 仓库里 cask 的 sha256 等于下载下来的 `shasum -a 256 /tmp/Tally.dmg`。
