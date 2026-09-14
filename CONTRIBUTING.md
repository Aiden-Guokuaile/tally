# 参与开发

> 给想改 Tally 的人：环境、命令、目录结构、约定。用户向的说明在 [README.md](README.md)，实现以 [docs/](docs/README.md) 为准。

## 环境

- macOS 15+、Apple Silicon、带刘海的 MacBook（面板只挂在带刘海的内建屏上）
- Xcode 16+（`Package.swift` 是 swift-tools 6.0，各目标 `swiftLanguageMode(.v5)`）

## 常用命令

```bash
swift build                                 # 编译三个目标
swift test                                  # 全部要绿；真机相关的用例在环境不满足时跳过
open -a Tally --args --open ai              # 启动即展开到那页并钉住（network / system / apps / shelf 同理）；--open settings 开设置窗口
screencapture -R256,0,1000,480 -x /tmp/tally.png   # 14 寸内建屏 1512pt 宽，面板居中、宽 620pt，高随内容
```

- 打包成 `.app`、签名、打 DMG 与发版的脚本不在仓库里；仓库只有源码、资源、测试和文档。
- `pkill -x Tally` 之后要等 `pgrep -x Tally` 查不到再 `open -a`，否则参数被旧实例吞掉。
- 验证 hook 时用 `TALLY_SESSIONS_DIR` 指到临时目录，别碰真的会话目录：

  ```bash
  export TALLY_SESSIONS_DIR=$(mktemp -d)
  echo '{"session_id":"t1","hook_event_name":"SessionStart","cwd":"/tmp"}' | /Applications/Tally.app/Contents/MacOS/tally-hook
  ```

- `claude -p` 和 `codex exec` 都不触发 Stop，`Stop → done` 只能在交互会话里验。

## 架构

```
Claude Code / Codex 的 hook ──stdin JSON──▶ Tally.app/Contents/MacOS/tally-hook ──tmp + rename──▶ ~/Library/Application Support/Tally/sessions/<id>.json
                                                                                                          │ kqueue
Tally.app（LSUIElement，无 Dock 图标）                                                                      ▼
  NotchController ── NotchPanel（贴刘海的 NSPanel，level 在菜单栏之上）── NotchView（页签 + 当前页 / 闭合态提示条）
       │ 采样起停、提示条、快捷键                                           ├─ AIPage：SessionStore + UsageStore
       │                                                                   ├─ NetworkPage：NetworkStore
       │                                                                   ├─ SystemPage：SystemStore
       │                                                                   ├─ AppsPage：RunningAppsStore
       │                                                                   └─ ShelfPage：ShelfStore
  SettingsWindowController ── 通用 / 面板 / 提示 / 文件架 / hook / 用量 / 关于
```

| 目录 | 职责 |
|---|---|
| `Sources/TallyKit/` | app 与 hook 共用：`SessionRecord`（状态文件模型、分组、陈旧 / 存活判定）、`HookDecision`（事件到状态的决策表）、`HookRunner`、`HookHeartbeat`（最近收到的事件）、`TranscriptTitle`（标题、模型、回合怎么结束的、是不是交互会话）、`ProcessTable` |
| `Sources/TallyHook/` | `tally-hook` 的入口：读 stdin、调 `HookRunner`、永远 exit 0、900 ms 自退 |
| `Sources/Tally/Notch/` | 面板壳与各页：`NotchPanel`、`NotchGeometry`、`NotchController`、`NotchView`、`HotKeyCenter`（⌥⇧T）、`SessionsPage`、`AIPage`、`UsageWidgets`、`NetworkPage`、`SystemPage`、`AppsPage`、`ShelfPage`、`SettingsPage`（设置各页签的表单）、`AlertSound`、`Theme` |
| `Sources/Tally/Sessions/` | `SessionStore`（目录监视、补判打断与报错、已关闭会话）、`TerminalLocator` 与 Ghostty / Terminal / iTerm / tmux 定位、`SessionResume`（接着聊）、`SessionFrontmost`（终端标签是否在前台） |
| `Sources/Tally/Usage/` | 移植自 Atoll 的用量核心与 Claude / Codex / Cursor / Antigravity、国内几家与 New API（`ProviderCredentials` 管手填的 key）、`UsageStore`、`QuotaAlerts`（配额提醒判定）、`QuotaBackoff`（429 退避） |
| `Sources/Tally/Network/` | 网卡计数、主接口、DNS、Wi-Fi、代理识别、可选的 mihomo 内核接口 |
| `Sources/Tally/System/` | 内存 / CPU / 磁盘、电池、废纸篓、保持唤醒、电池事件、摄像头 / 麦克风占用、菜单栏小恐龙 |
| `Sources/Tally/Apps/`、`Shelf/` | 在跑的 app；文件架 |
| `Sources/Tally/Install/` | `HookInstaller`（两侧注册与移除、Codex 信任哈希）、`HookInstallModel`（状态、最近收到事件、`HookSelfTest` 自检）、`LoginShell`（`CodexHome`，问登录 shell 拿环境变量和 PATH） |
| `Sources/Tally/Settings/` | `SettingsWindow`（设置窗口与页签切换）、`HelpPage`（关于页） |
| `Resources/` | `Info.plist`、`pricing.json`、提供方标志、应用图标、关于页图案、小恐龙逐帧图 |
| `docs/` | 按页面 / 模块分的设计文档，实现以它们为准；`docs/images/` 是 README 用的截图 |

## 约定

- **先改文档再改代码**。`docs/` 按页面分（目录见 [docs/README.md](docs/README.md)），行为、边界、验证命令都写在里面，写当前状态，不记历史。
- **零第三方依赖**；有真实第二个调用点才抽公共函数，没出过的异常不加 try/catch。
- **中文注释**，写「为什么」不写「是什么」。
- **hook 三条硬约束**：永远 exit 0（Stop 上 exit 2 会阻止 agent 结束回合）、900 ms 自我退出、校验不过不写文件。
- **Claude 配额只读**：不碰刷新用的 token、不调刷新接口、不往凭据文件或钥匙串写。
- **移植自 Atoll 的文件**清单在 [NOTICE](NOTICE)：改过的在文件头第二行注明改了什么，其余除文件头外逐字不动。
- commit message 用中文。
