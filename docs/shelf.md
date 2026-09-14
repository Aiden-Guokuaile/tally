# 「文件架」页

> 把文件拖到刘海上，面板展开到文件架并暂存一份副本；从这里拖出去、AirDrop、打开，3 天后自动清理。按住 ⌘ 拖出去是「剪切」：访达把**来源文件本身**搬到目标，架上那份副本随后清掉。交互形态照 NotchDrop（MIT），代码是重写的，理由在下面。

## 拖放

拖放目标挂在面板根视图上（`NotchView` 的 `.onDrop(of: [.fileURL])`），闭合和展开都接：

- 闭合态文件拖到刘海上（`isTargeted` 变真）→ `NotchState.dropEntered` → 控制器切到文件架页并展开（不钉住，拖走了照常按光标位置收起）。
- 展开态拖到任何一页上 → 切到文件架页；落下后 `ShelfDrop.handle` 从 item provider 里取 `public.file-url`，交给 `ShelfStore.add(urls:)`。
- 开关关了 `.onDrop` 的类型列表为空，等于不注册拖放目标。

**拖进来永远是复制**，来源文件原地不动：架上这份是副本，3 天后自动清理，它要是唯一一份就会丢文件。要剪切在拖出去那一步做。

## 拖出去与剪切（`ShelfDragSource`）

拖出去默认是复制：目标目录多一份，架上和来源都还在。**按住 ⌘ 拖出去**（访达的老约定）是移走。右键「移动到…」是同一件事的确定性版本——弹系统的选目录面板，不依赖修饰键和访达的判断。选目录面板和移动失败的提示框都包在 `NotchPanel.steppingAside` 里，否则被面板盖住（见 [panel.md](panel.md)）。

**交出去的 URL 是来源文件本身，不是架上那份副本**（`ShelfStore.cutURL`）。交副本的话，「剪切」就成了「把暂存那一刻的快照搬到目标，再把来源删掉」：盘上凭空多一次整文件的复制（11 MB 也好 2 GB 也好），目标拿到的还是旧内容，来源那份还得想办法处置（第一版是丢进废纸篓，于是一次剪切在盘上留下两份 11 MB 的东西）。交来源就是访达自己做一次改名：同卷瞬时、内容是当前的，架上那份副本直接删掉即可。来源已经不在原处（自己动过、或者本来就是从 Safari 拖来的临时文件）才退回交架上那份。

拖源不能用 SwiftUI 的 `.onDrag`：它只交出一个 `NSItemProvider`，拿不到拖放结束时目标执行的到底是 copy 还是 move，删早了会丢文件。所以改成 AppKit 的拖放会话——`ShelfDragSource` 是个空的 `NSView`（`.background` 里，`hitTest` 返回 nil，不吃点击、不挡 hover 和右键），SwiftUI 那边用 `DragGesture(minimumDistance: 4)` 起会话：

- `draggingSession(_:sourceOperationMaskFor:)` 交 `[.copy, .move]`，按不按 ⌘ 由访达定。只给 `.move` 的话不按 ⌘ 也会搬走。
- `draggingSession(_:endedAt:operation:)` 拿结果：`.move` 走 `ShelfStore.remove`（文件已经被访达搬走了，这里只清架上那份副本和索引），`.copy` 和 `[]`（拖到没人接的地方）什么都不做。
- 起会话要一个鼠标事件，用 `NSApp.currentEvent`；拿不到就记一行日志并放弃，不硬来。

## 存储（`ShelfStore`）

目录 `~/Library/Application Support/Tally/shelf/`：`index.json`（每件的 id、名字、大小、加入时刻、来源路径——剪切要靠它找回来源文件，老索引缺这个键解出来是 nil，原子写）、`files/<id>/<原文件名>`（副本，各自一个目录所以同名不冲突）、`thumbs/<id>.png`（QuickLook 缩略图 96pt @2x，生成不了的用文件图标）。复制在后台线程；`add` 是 async，界面用 `Task` 调。

内存只有索引里的几个字段；缩略图只在这页可见时（`start()`）读进内存，收起或切页（`stop()`）就放掉；开关关掉（`setEnabled(false)`）索引也放掉，磁盘上的东西不动，再开还在。保留期 `retention` = 3 天，开关打开和每次这页可见时清一次过期项（`expired(_:now:)` 纯函数）。

和 NotchDrop 的差别：它把缩略图当 PNG `Data` 常驻内存并 base64 进 JSON、启动即解码全部条目、常驻全局鼠标监视器和 1 Hz 定时器；这里没有任何常驻监听，关掉零内存。

## 页

卡片顶行「N 项 · 保留 3 天」（空的时候是提示语）+ 右侧「AirDrop 全部」「清空」；下面自适应网格，每件缩略图 44pt + 名字（中间截断）+ 大小。点开（`NSWorkspace.open`），按住拖出去是文件本身（⌘ 是剪切，见上），悬停右上角出删除叉，右键：打开 / AirDrop / 移动到… / 在访达中显示 / 删除。AirDrop 走 `NSSharingService(named: .sendViaAirDrop)`，面板不抢激活，调之前先 `NSApp.activate` 系统面板才出得来。空态是 160pt 高的虚线框「拖文件到这里」，有东西时网格也至少 160pt：拖放靶子给足，页也不至于矮得像残页。

设置窗口「文件架」一节：开关、存放位置（在访达中显示）、已暂存几项、清空。

## 验证

```bash
swift test --filter 'ShelfStoreTests|PreferencesTests'
./scripts/install.sh --build && sleep 3; pkill -x Tally; while pgrep -x Tally >/dev/null; do sleep 0.5; done
open -a Tally --args --open shelf && sleep 5 && screencapture -R256,0,1000,480 -x /tmp/tally-shelf.png
```

用例：加两份同名文件各自成项且副本存在、重开实例索引还在、删除连文件一起删、清空；没开不收、可见时缩略图在内存、不可见放掉、关掉索引清空但磁盘保留；过期判定；`cutURL` 来源还在时交来源、来源没了退回架上那份；老索引缺 `source` 能解出来；「移动到…」搬的是来源、架上那份跟着清掉、废纸篓里不多东西，目标已有同名文件时报错且什么都不动。截图：空态虚线框；手动：从访达拖一个文件到刘海上 → 面板展开到文件架并出现该项；把它拖回桌面得到一份副本，来源还在；**按住 ⌘ 拖回桌面 → 桌面有、架上那件消失、来源原处没有了且废纸篓里也没有**（它是被改名过去的）；右键 AirDrop 出系统面板。
