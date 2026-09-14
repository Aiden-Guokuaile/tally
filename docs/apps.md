# 「应用」页

> 在跑的 app，按内存降序；Dock 里看不见的（菜单栏工具、纯后台）名字后面带「眼睛划掉」图标。点行打开，右键退出。

## 哪些算（`RunningApps.isHidden`，纯规则，返回三态）

`NSWorkspace.runningApplications` 里：

| 条件 | 结果 |
|---|---|
| `activationPolicy == .regular`（Dock 里看得见，⌘Tab 里那些，不管谁出的） | 算，不是隐藏 |
| `.accessory` 且 bundle 路径在 `/Applications/` 或用户目录下、路径里只有一层 `.app`（嵌在别的 app 包里的 Helper 滤掉）、bundle id 不以 `com.apple.` 开头 | 算，隐藏 |
| 其余（`.prohibited`，系统的后台 accessory） | 不算 |

Tally 自己也按这套算：平时是 accessory（`LSUIElement`）算隐藏，开着设置窗口时是 regular。不列没在跑的，不做启动器。

已知边界：第三方后台 app 若装在 `/Library/Application Support/…`、`/opt/homebrew/…` 这类既不在 `/Applications` 也不在家目录的位置，会被第二条的位置判定挡掉。保留这个保守写法是取舍：翻成黑名单（排除 `/System`、`.xpc`、`.appex`…）要维护一份开放的排除清单，macOS 换个容器路径就会把系统内部件放进面板——错误方向从「少列一个后台工具」变成「列进系统内部件」，对刘海面板前者可接受得多。有真实漏报案例再改。

## 行

图标（运行中程序自己报的 `NSRunningApplication.icon`，拿不到退回文件图标）+ 名字 + 隐藏的加 `eye.slash` 小图标+ 物理内存（`proc_pid_rusage`，只算主进程，浏览器的 Helper 不计）。按内存降序，同样大按名字。悬停行有底色。停在这页时每 2 秒重列，标题行 ↻ 立刻重列。

列举、读内存、取图标全在后台跑（`Task.detached`，带轮次编号，旧一轮不盖新一轮），主线程只收结果：`NSRunningApplication.icon` 一个 3.5 ms（32 个尺寸、最大 2048px），十几行 50 ms，原来写在视图 body 里，切页、每 2 秒刷新、悬停都重来一遍，切页时正好卡在高度动画里。图标按 pid 缓存成 36px 位图（`RunningAppsStore.smallIcon`），进程没了就丢；还没取到时先画通用 app 图标占位。

- 点行：`NSWorkspace.openApplication(at:)`，激活并触发 reopen，菜单栏 app 通常会弹主窗口；失败记日志。
- 右键「在访达中显示」：`NSWorkspace.activateFileViewerSelecting`。「Updater」「Helper」这类通用名字看不出归属，路径里才有（微信的 Sparkle 更新器住在 `~/Library/Caches/com.tencent.xinWeChat/…`）。不用悬停提示：面板不抢激活，AppKit 画不出来（见 [panel.md](panel.md)）。
- 右键「退出 <名字>」：`NSRunningApplication.terminate()`，等同 ⌘Q，对方可以弹保存或拒绝；不强杀。退出 Tally 自己走 `NSApp.terminate`（`terminate()` 对当前进程无效）。面板展开时右键交给 SwiftUI 才弹得出来（闭合态右键刘海仍是 Tally 菜单）。

## 验证

```bash
swift test --filter RunningAppsTests
pkill -x Tally; while pgrep -x Tally >/dev/null; do sleep 0.5; done
open -a Tally --args --open apps && sleep 5 && screencapture -R256,0,1000,480 -x /tmp/tally-apps.png
```

用例：小图标缩到 36px 且不超过；规则十一条（regular 算且不隐藏、苹果的 regular 也算、accessory 在 /Applications 算隐藏、用户目录算、prohibited 不算、嵌套 Helper 不算、系统目录的 accessory 不算、`com.apple.` 的 accessory 不算、自己 accessory 算隐藏、自己 regular 算不隐藏、名字里带 app 三个字母不算嵌套）、真实列表按内存降序且 Tally 在跑时含自己、Finder 在列表里且不隐藏、随便一个在跑的菜单栏 app 在列表里且标隐藏（没有就跳过）。截图：列表有图标、名字、内存，菜单栏 app 名字后有图标。手动：悬停高亮，点一行它弹出来，右键出「退出 xxx」。
