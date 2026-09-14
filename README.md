# Tally

MacBook 刘海里的信息面板。鼠标停在刘海上就展开，五个页签：

- **AI**：哪个 Claude Code / Codex 会话在等审批、等输入、刚跑完，点一行跳回它的终端窗口；下面是 Claude / Codex / Cursor / Antigravity 的配额百分比、重置时刻、今日与本周费用。会话行带模型标志与名字（如 Opus 5、gpt-6-astra）。
- **网络**：网卡吞吐（最近 60 秒折线）、连接（Wi-Fi 信号、本机 IP、网关、DNS）；有代理软件在跑时多一张卡片：认出是谁、端口 / TUN / 模式、一键打开它。
- **系统**：芯片 / 核心 / 内存 / macOS / 开机时长，电池电量与健康，内存（含内核压力等级）/ CPU / 磁盘，内存大户前三，废纸篓大小与一键清空。
- **应用**：在跑的 app 按内存排，Dock 里看不见的（菜单栏工具、后台 app）带标记，点行打开，右键退出。
- **文件架**：把文件拖到刘海上暂存一份副本，拖出去、AirDrop、打开，3 天后自动清理。

闭合态纯黑，有事时往下垂提示条：会话跑完一个回合、接电 / 拔电 / 低电 / 充满；摄像头 / 麦克风被占用时标题行画点。标题行有「保持唤醒」按钮。⌥⇧T 开合，两指横滑、三指轻扫或数字键翻页，面板高度跟着内容走；每个功能都有开关，关掉不起监听不占内存；设置在独立窗口。原生 SwiftUI + AppKit，零第三方依赖，macOS 15+，只在带刘海的内建屏上显示。一切数据都在本机，不收集、不上传。

## 跑得起来的条件

| 项 | 要求 | 卡在哪 |
|---|---|---|
| 系统 | **macOS 15+** | `Info.plist` 的 `LSMinimumSystemVersion = 15.0`；用到 `@Observable`、`Scene.defaultLaunchBehavior`、`onGeometryChange` 这一代 API |
| 芯片 | **Apple Silicon** | 构建脚本不做 universal，产出的是 arm64 单架构二进制（`lipo -archs` 可验），Intel 机器装不上 |
| 屏幕 | **带刘海的内建屏** | 面板只挂在 `CGDisplayIsBuiltin` 且 `safeAreaInsets.top > 0` 的屏上——2021 年后的 14 / 16 寸 MacBook Pro、M2 之后的 MacBook Air。别的机器 app 能启动，但面板永远不出现 |
| 依赖 | 无 | 零第三方依赖，全是系统框架 |

要权限的只有三处，不用就不给：点会话行跳回终端要「自动化」授权；「合盖也不休眠」第一次开要一次**管理员密码**（装一条只放行两条 `pmset` 的 sudoers 免密规则，见 [docs/monitors.md](docs/monitors.md)，**非管理员账号用不了这一项**，其余功能不受影响）；查 Claude 配额借 `security` 工具只读 token，不弹框。屏幕录制、摄像头、麦克风一概不要。

## 安装

```bash
./scripts/install.sh --build     # 编译 + 装进 /Applications + 启动
```

或者用 `./scripts/build-dmg.sh` 打成 DMG 给别人：拖进 Applications，首次打开过一次 Gatekeeper（分发那份由 `build-dmg.sh` 重签成 ad-hoc——本机自签的「Tally Dev」证书在别人机器上不受信任，签名验不过会被报「已损坏」，比 ad-hoc 的「无法验证开发者」更吓人），然后在设置窗口点两个「安装」把 Claude Code / Codex 的 hook 注册上；首次点会话行会弹终端自动化授权；查用量不弹框（借 `security` 工具只读 token，不碰钥匙串密码）。**「合盖也不休眠」是唯一会要管理员密码的功能**：不点它就什么都不装，点了会说清楚要装哪条规则、怎么撤（设置窗口「面板」里取消勾选即可），非管理员账号用不了这一项、其余功能不受影响。卸载：设置里点两个「移除」退掉 hook 注册，再删 Tally.app。

## 怎么用

| 动作 | 效果 |
|---|---|
| 鼠标停在刘海上 0.15 秒 / 移开 0.3 秒 | 展开 / 收起 |
| ⌥⇧T | 展开（钉住，不自动收）/ 收起；设置里可关 |
| 点页签、两指横滑、三指轻扫 | 翻页，记住上次点开的页 |
| 标题行 ↻ | 刷新当前页（AI 页刷用量，60 秒节流；其余页立刻重采） |
| 齿轮、右键刘海、展开时 ⌘, | 设置窗口（开机自启、快捷键、hook 安装 / 移除、用量条显示哪几家）与帮助 |
| 点会话行 | 跳回终端：Ghostty 按目录 + 标题，Terminal.app / iTerm2 按 tty 切 tab，VS Code / Cursor / Warp / kitty / WezTerm 只激活 |
| 代理卡片「打开 ▸」或双击 | 打开那个代理软件 |
| 应用页点行 / 右键 | 打开 / 正常退出（等同 ⌘Q，不强杀） |
| 系统页「清空」 | 确认后永久删 `~/.Trash` 里的东西 |

数据来源：会话来自 Claude Code 与 Codex 的 hook（只有它们有 hook 机制）；用量来自本地日志和各家官方接口，Claude 只读登录留下的 access token，不刷新、不回写；网络、系统、应用页全走 macOS 公开 API（`getifaddrs`、SystemConfiguration、CoreWLAN、sysctl、IOKit 注册表、libproc）。有 mihomo 内核控制接口（Unix socket `/tmp/gauge/core.sock`）的机器上，代理卡片还会列各组当前节点；没有就只显示系统代理那几行。

## 架构

```
Claude Code / Codex 的 hook ──stdin JSON──▶ Tally.app/Contents/MacOS/tally-hook ──tmp + rename──▶ ~/Library/Application Support/Tally/sessions/<id>.json
                                                                                                          │ kqueue
Tally.app（LSUIElement，无 Dock 图标）                                                                      ▼
  NotchController ── NotchPanel（贴刘海的 NSPanel，level 在菜单栏之上）── NotchView（页签 + 当前页）
       │ 采样起停                                                          ├─ AIPage：SessionStore + UsageStore
       │                                                                   ├─ NetworkPage：NetworkStore（InterfaceSampler、ProxyAppDetector、可选 MihomoClient）
       │                                                                   ├─ SystemPage：SystemStore（SystemSampler、TrashInfo）
       │                                                                   └─ AppsPage：RunningAppsStore
  SettingsWindowController ── 设置 / 帮助两个页签 ── HookInstaller（注册 / 移除）
```

| 目录 | 职责 |
|---|---|
| `Sources/TallyKit/` | app 与 hook 共用：`SessionRecord`（状态文件模型、陈旧 / 存活 / 清理判定）、`TranscriptTitle`、`HookDecision`（事件到状态的决策表）、`ProcessTable`（sysctl 找 agent 进程与 tty）、`HookRunner` |
| `Sources/TallyHook/` | `tally-hook` 的 main：读 stdin、调 HookRunner、永远 exit 0、900 ms 自退 |
| `Sources/Tally/Notch/` | `NotchPanel`、`NotchGeometry`（尺寸、找内建屏、高度随内容）、`NotchController`（悬停、点外、右键、`--open`、⌥⇧T、⌘,、手势翻页、采样起停）、`HotKeyCenter`、`Theme`（Card / KeyValueRow / MetricBar / TabBar）、四个页 |
| `Sources/Tally/Sessions/` | `SessionStore`（目录监视）、`TerminalLocator` 与 Ghostty / Terminal.app / iTerm2 三个定位实现 |
| `Sources/Tally/Usage/` | 移植自 Atoll 的用量核心与四个 provider、`ClaudeLimitsCache`、`ClaudeQuotaReadOnly`、`UsageStore` |
| `Sources/Tally/Network/` | `InterfaceSampler`（网卡计数、主接口、DNS、Wi-Fi、系统代理、TUN）、`ProxyAppDetector`（端口反查 + 父进程回溯 + 已知名单）、`MihomoClient` / `ChunkedDecoder`（可选内核接口）、`NetworkStore` |
| `Sources/Tally/System/` | `SystemSampler`（内存 / CPU / 磁盘、压力等级、内存大户、`HardwareInfo`、`BatteryHealth`）、`TrashInfo`、`SystemStore`、`ByteFormat` |
| `Sources/Tally/Apps/` | `RunningApps`（哪些在跑的 app 列出来、哪些算「Dock 看不见的」）、`RunningAppsStore` |
| `Sources/Tally/System/KeepAwake.swift`、`BatteryWatcher.swift`、`PrivacyWatcher.swift` | 跟着设置开关起停的小工具与监听：电源断言、电池事件、摄像头 / 麦克风占用（`docs/monitors.md`） |
| `Sources/Tally/Shelf/` | `ShelfStore`：文件架的索引、副本、缩略图、过期清理（`docs/shelf.md`） |
| `Sources/Tally/Install/` | `HookInstaller`（两侧注册与移除、Codex 信任哈希、状态）、`HookInstallModel` |
| `Sources/Tally/Settings/` | `SettingsWindowController`、`HelpPage` |
| `Resources/` | `Info.plist`、`pricing.json`、`icons/make-icon.swift`（生成 `AppIcon.icns`） |
| `scripts/` | `build-app.sh` 组装 .app，`install.sh` 装进 /Applications，`build-dmg.sh` 打分发镜像 |
| `docs/` | 按页面 / 模块分的设计文档，实现以它们为准：[docs/README.md](docs/README.md) |

会话状态文件、事件映射、hook 硬约束在 [docs/ai.md](docs/ai.md)；注册与移除在 [docs/hooks.md](docs/hooks.md)。

## 开发

```bash
swift test                          # 160 个用例，全部要绿；真机相关的用例在环境不满足时跳过
./scripts/install.sh --build        # 改完必跑，用户用的是 /Applications 里那份
open -a Tally --args --open ai      # 面板启动即展开到那页且不自动收起（network / system / apps 同理）；--open settings 开设置窗口
screencapture -R256,0,1000,480 -x /tmp/tally.png    # 14 寸内建屏 1512pt 宽，面板居中 620pt
```

`pkill -x Tally` 后要等 `pgrep -x Tally` 查不到再 `open -a`，否则参数被旧实例吞掉。hook 与会话文件的验证用 `TALLY_SESSIONS_DIR` 指到临时目录。项目约定在 `.claude/CLAUDE.md`（与 `AGENTS.md` 同文）。

## 许可

GPL-3（`LICENSE`）。用量数据层移植自 [Atoll](https://github.com/Ebullioscopic/Atoll)（GPL-3.0），15 个文件的清单在 `NOTICE`，标「不改」的文件除文件头外逐字未动。
