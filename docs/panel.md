# 刘海面板

> 贴在 MacBook 刘海上的 NSPanel：闭合态纯黑、和刘海融为一体，有事时往下垂提示条；展开态是页签 + 当前页；设置和帮助在独立窗口。

## 找内建屏

`NotchGeometry.builtInNotchScreen()`：遍历 `NSScreen.screens`，取 `deviceDescription["NSScreenNumber"]` 得显示器 id，`CGDisplayIsBuiltin != 0` 且 `safeAreaInsets.top > 0` 的那一个；没有就返回 nil，控制器 `orderOut` 并按收起处理（采样一起停）。不用 `NSScreen.main`：接外接屏时它可能是外接屏。`NSApplication.didChangeScreenParametersNotification` 到了就重找。

## 窗口属性（`NotchPanel`）

`NSPanel`，`styleMask = [.borderless, .nonactivatingPanel]`，`level = .mainMenu + 3`，`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`，`isFloatingPanel`、`hidesOnDeactivate = false`、无阴影、背景透明，`canBecomeKey = true`（展开态的按钮要收到点击）。

**收起时必须把键盘焦点还回去**：`open()` 里 `makeKeyAndOrderFront` 之后，键盘焦点从前台 app 转到 Tally 进程（非激活面板就是「不激活也能收键盘」）；`close()` 不交还的话，面板缩回刘海了焦点还在它身上，之后打的字全进面板，直到用户点一下别处。所以 `close()` 里面板仍是 key 就 `resignKey()`。探针实测（AX 的 `kAXFocusedUIElementAttribute` 读焦点属于哪个进程）：makeKey 后属面板进程，什么都不做就一直留在那儿；`resignKey()` 后回到原来的 app，再 makeKey 照常拿回，连做三轮一样。`orderOut` + `orderFrontRegardless` 也能还，但会重排窗口，不用。面板不抢激活，所以主菜单的快捷键收不到，见「键盘」；**`.help(…)` 的悬停提示在这个面板里靠不住**：AppKit 只在 app 处于前台时画提示，而面板展开时前台仍是别的 app（实测钉住面板时 `lsappinfo front` 返回的是别的 app，不是 Tally）。应用页实测悬停整行没有任何提示出现，所以要给行加说明走右键菜单或直接画在行里。页签名字、刷新按钮的「更新于 HH:mm」、摄像头 / 麦克风占用点、文件架文件名这几处也用 `.help`，它们到底出不出现没验证过——真要依赖，先拿一次悬停实测确认。`sharingType` 跟着「截屏和共享屏幕时隐藏面板」开关走（[monitors.md](monitors.md)）。

**面板会盖住本 app 的模态窗口，弹系统 UI 前必须让路**：`NSApplication.runModal` 在模态循环启动时把模态窗口的 level 钉死在 `.modalPanel`（8），面板是 `.mainMenu + 3`（27），27 > 8，窗口服务器就把面板排前面——弹框在面板底下，看不见也点不到。跟激活状态无关（实测模态中 `NSApp.isActive`、`isKeyWindow` 都是真，照样在后面），`NSApp.activate` 解决的是「系统 UI 出不出得来」，不是 z 序。

所以凡是从面板里弹 `NSAlert` / `NSOpenPanel` 的地方，都把 `runModal()` 包进 `NotchPanel.steppingAside { … }`：期间把面板压到 `.normal`，`defer` 还原。三条排掉的错误修法：`runModal` **之前**设 alert 的 level 会被 AppKit 踩回 8；`addChildWindow` 同样被打散；进了模态再用 `.modalPanel` 模式的定时器抬起来能行但更脏，且救不了别的进程呈现的面板（AirDrop 那种）。压面板对所有情况一视同仁。

**不要改成 `beginSheetModal(for:)`**——这是最像「正确 AppKit 做法」的错答案。`runModal` 会冻住默认模式的 run loop（实测模态期间默认模式的 `Timer`、`Task { @MainActor }`、`DispatchQueue.main.async` 各跑 0 次），每 100 ms 的 `hoverPoll` 因此停摆，面板不会在弹框还开着时自己收起——这是现在能用的隐性依赖。换成 sheet 就没有嵌套模态循环，鼠标一离开面板就收起，挂在它身上的 sheet 跟着一起没。

## 尺寸（`NotchGeometry`，纯函数）

| 状态 | 宽 | 高 |
|---|---|---|
| 闭合 | `frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width + 4`（多 4pt 盖住刘海圆角缝） | `safeAreaInsets.top` |
| 展开 | 620 固定（两侧各 19 是肩部弧线占掉的，黑块实际 582；标题行左右各约 180pt：左边放得下 6 颗只有图标的页签，右边 5 颗按钮已满；字号固定，更宽只是留白） | `openHeight(content:screenHeight:) = min(max(content + 56, 160), screenHeight × 0.6)` |
| 提示 | 内容宽 + 两侧各 `peekPadding`（12），夹在闭合宽与 `peekMaxWidth`（420）之间；第一帧用 `Peek.estimatedContentWidth` 估，内容量出实际宽度后再动画收紧 | 闭合高 + `peekDrop`（46） |

14 寸实测：1512 / 663 / 664 / 32 → 闭合 189 × 32，物理刘海 185pt。**这 189 里画什么都看不见**：那是摄像头外壳，没有像素；截图抓的是帧缓冲，照样拍得到，所以截图验收发现不了——闭合态因此什么都不画。展开高度里的 56 是顶栏与内边距；`content` 由页视图 `onGeometryChange` 报到 `NotchState.contentHeight`，展开中变化就动画换帧；内容超过上限时页内容滚动（页内容套 ScrollView，否则 VStack 溢出会把顶部裁掉）。面板 frame 锚点始终是内建屏顶部中央。

## 形状与动效

照 Atoll：`NotchShape(top:bottom:)` 的路径是「顶角向外翻的肩部弧线 + 底角圆角」，两个半径都在 `animatableData` 里，闭合 0 / 12，展开 19 / 24，随开合一起插值；肩部把竖边向内缩 `top`，所以展开态页内容的横向内边距是 `shoulder + 12`。面板 frame 由 AppKit 动画（展开 0.38 s、收起 0.30 s，expo-out 曲线 `(0.16, 1, 0.3, 1)`，不用弹簧是因为 `NSAnimationContext` 只吃 timing function；展开着只变高度的用 0.2 s easeOut）；展开态内容用 `.blurReplace` 延迟 0.1 s 从模糊里浮现，收起时直接淡出。不做窗口阴影：可见窗口上翻转 `hasShadow` 会重建窗口 surface，AppKit 随即合成 mouseExited / mouseEntered，光标停在刘海上面板会开、关、再开地闪（日志实测，光标坐标始终在 frame 内）；Atoll 也是关掉 `hasShadow` 自己在 SwiftUI 里画，那需要 frame 比黑块大一圈，牵连追踪区和点击，不做。面板本身永远纯黑，不做材质。

## 交互（`NotchController`）

- 闭合态 `NSTrackingArea` 监听鼠标进入，停 150 ms 展开（设置里「鼠标停在刘海上展开」可关，关了靠 ⌥⇧T）；进入后又离开就作废。展开后不再信追踪区，每 100 ms 看一次 `NSEvent.mouseLocation` 在不在面板 frame 内，离开满 150 ms 收起（Atoll 是 100 ms），中途回来作废；鼠标按着（`NSEvent.pressedMouseButtons`）时不收——那是在拖文件进来或从文件架拖出去，光标必然要离开面板，收起会把拖拽掐断。判在不在面板上用 AppKit 的 `NSMouseInRect(p, frame, false)`（顶边算里面，和追踪区同一套规则），不用 `CGRect.contains`：后者不含顶边，而面板顶边就是屏幕顶边，光标甩到刘海上会被卡在最顶那一行——追踪区说进来了、轮询说在外面，首次悬停开了又收。收起定时器在 `open()` / `close()` 里置空（不只作废）：触发过的定时器还挂在变量上的话，轮询「还没排收起」的判断永远不成立，那个「开了又收」只在进程里第一次出现，之后被盖住，光标沿顶边溜走时面板还会一直不收。面板在光标脚下缩小（切到矮的页、卡片消失）也不算离开：`applyFrame` 记下缩小前的 frame，`HoverGrace.judge` 认光标还在那块老区域里就当在面板上，回到面板里或真离开才清掉。追踪区只在闭合态可信：窗口动画期间 `updateTrackingAreas` 要到动画结束才被调用，AppKit 拿闭合态的 189 × 32 矩形去比对已经长大的窗口，会合成光标明明在面板上的离开事件（日志实测：EXIT 的 `locationInWindow` 在 frame 内），面板就开、关、再开地闪。另外两条：只认自己那一个追踪区（`event.trackingArea === trackingArea`，SwiftUI 的 `.onHover` 也往同一个 NSHostingView 里装追踪区，光标从一颗按钮上挪开也是一次 mouseExited）；刚收起的 400 ms 内忽略进入事件（收起动画里 AppKit 同样会合成一次进入，否则 ⌥⇧T 收起时光标停在面板上会立刻重开）。
- 展开时刷一次用量（`UsageStore.refresh(reason: .panelOpened)`），并按当前页起采样（网络 / 系统 / 应用），收起时全部停；展开中切页签先停上一页再起新页。
- 展开态挂 `NSEvent.addGlobalMonitorForEvents(.leftMouseDown)`：点面板外立即收起。
- 钉住态（`--open`、⌥⇧T）不因鼠标离开或点外收起，再点一次刘海才收：只认点在刘海那段——顶部 `notchHeight` 高、横向在标题行给物理刘海留的空位（`headerGap`）里，`NotchGeometry.hitsNotch` 判；点页签、按钮、页内容都不收。`NotchHostView.mouseDown` 对面板里每一次左键都会调（SwiftUI 的按钮也先经过它），不按位置判的话钉住后点任何页签面板都会收起。`open()` 对已展开的面板是空操作，连 `isPinned` 都不碰：悬停定时器晚 150 ms 才到，不能把刚钉住的改回不钉。
- 闭合态右键刘海出 Tally 菜单（设置… / 刷新用量 / 退出）；展开态右键交给 SwiftUI，页面里的右键菜单（应用页的「退出」）才弹得出来。
- 启动参数 `--open ai|network|system|apps|shelf` 展开到那页并钉住（截图用，不写 `lastPage`）；`--open settings` 开设置窗口；`--install-hooks` 不开面板，同步装两侧 hook，结果打到 stdout 后退出。

## 闭合态内容

闭合态纯黑，什么都不画：刘海正下方是摄像头外壳，没有像素，画了也看不见（见「尺寸」）。试过向刘海两侧长翅膀画「在等我的会话数」和 Claude 5 小时配额，但翅膀一行只放得下一家的配额，同时用几家的时候看不全，不如展开看，删了。有事靠下面的提示条；摄像头 / 麦克风占用点、等待徽标在展开态标题行。

### 提示（`Peek`）

面板闭合时有事发生，刘海往下垂出一条（形态照 Atoll 的 sneak peek 标准式：往下 46pt，底角 18，宽度跟着内容走、最窄和刘海一样宽，不横着占菜单栏——第一版是左右长翅膀，盖菜单栏又丑；第二版固定比刘海宽 36pt，字少时一大块黑，都换了）：上面 `notchHeight` 那段留给刘海，下面一行是着色图标（图标色 16% 底的圆角方块里）+ 着色短标签 + 标题，再一行灰字副标题。点提示条（只有会话类可点，电池类连手势都不挂）：按设置里「点提示条时」三选一——**跳回那个终端**（`TerminalLocator.focus`，失败只记日志；默认：提示条说的就是那个会话，点它就是要过去）、**展开到 AI 页**（`open(pinned: true)`，人是特意点过来看的，不钉住的话手一挪就收了）、**两者都要**。提示条随之收起。

这条点击曾经**根本不可能成功**，两条原因叠在一起，缺一条都修不好：

1. **首次点击被 AppKit 吞掉**。面板是 `.nonactivatingPanel`，提示态从不 `makeKeyAndOrderFront`（只有 `open()` 里才调）。AppKit 对非 key 窗口的首次左键点击的规矩是「拿它把窗口变 key，然后丢弃」，除非命中视图的 `acceptsFirstMouse` 返回真。`NotchHostView` 现在覆盖了它（实测：不覆盖 `mouseDown=0`，覆盖后 `mouseDown=1`）。不能在 `mouseDown` 里补救——它压根不会被调用。
2. **悬停展开抢在点击之前把提示条清掉了**。光标进面板 150 ms 就 `open()`，而 `open()` 第一件事是 `clearPeek()`；人从「光标落到目标上」到「按下鼠标」要 200–400 ms，所以点击永远落在已经展开的面板上，而那个位置正好是标题行给物理刘海留的空位（`headerGap`），空的。现在 `hoverStarted()` 在**会话类**提示条挂着时不起定时器；提示条到期收回的那一刻，若光标还在 `panel.frame` 内才补起一个。只拦会话类：电池提示条也拦的话，悬停展开要被堵住一整条提示条的时间。追踪区只在光标真正跨界时发 `mouseEntered`，光标不动就再也不发，所以到期那一刻必须主动查一次 `NSEvent.mouseLocation`。

两个来源：

- 会话事件（`SessionStore.sessionAlert`，判定见 [ai.md](ai.md) 的「提示」）：跑完一个回合是绿勾 +「Claude」「Codex」，标题是会话标题，副标题是回合最后一句话的开头（`message` 为空就是「跑完了 · 点这里跳过去」；API 报错结束的回合是那句报错，按 Esc 打断的不弹，见 [ai.md](ai.md)「打断与 API 报错」），停留时长按设置里的「会话提示停留」（默认 5 秒）；进入等审批 / 等输入是橙叹号 / 黄问号 +「等审批」「等输入」，副标题「Claude 在等你点一下 · 点这里跳过去」，比跑完多留 `Peek.askExtra`（3 秒）——真要人来的那种该多给点时间。
- 电池事件（[monitors.md](monitors.md)）：接电、拔电、低电、充满各一种图标与文案，停留时长按设置里的「电池提示停留」（默认 3 秒）。

入场动效（`PeekContent` / `PeekIcon`，全是 SwiftUI 自带的动画与符号动效，`peek.id` 一变视图重建、动画重放）：图标块从中心用欠阻尼弹簧弹出，同时向外扩一圈同色涟漪；标题行从刘海底下往下滑出，副标题晚 0.1 s 跟上。图标按 `style` 各有动作：会话完成先画满圆环再从左到右画勾，勾画完从中心撒一把十二片彩纸（角度距离按序号定，不用随机数）；接电闪电向上弹一下并持续脉动；拔电插头往下弹一下；低电电池脉动加轻晃；充满电池弹一下、右上角撒一颗星。电源文案见 [monitors.md](monitors.md)。

到时收回（时长 `Peek.duration(session:battery:)`，两个秒数在设置里调，2 到 30 秒）；期间又来一条就换成新的并重新计时；电池类的鼠标进来照旧悬停展开、提示随之消失，会话类的要等它到期（见上）。面板展开时不弹（会话那一行已经变成绿勾或橙叹号）。提示条比刘海宽出去的部分会盖住紧挨刘海的一点菜单栏，不做 Atoll 那种量菜单位置再避让。

## 页签与手势

- 标题行三段（照 Atoll）：页签靠左，右段依次是等待徽标、摄像头 / 麦克风占用点、「保持唤醒」杯子（设置里可关，右键菜单里可切屏幕常亮，[monitors.md](monitors.md)）、刷新、齿轮；「更新于 HH:mm」放在刷新按钮的悬停提示里，60 秒内刚刷过才在旁边显示两秒；中间 `headerGap(closedWidth:)` = 闭合刘海宽 + 8 的空位，两段各占剩余宽度的一半，所以空位正好对着物理刘海——不留空的话第四颗页签正好钻到刘海底下（截图看得见是因为截图连刘海底下的像素也截）。
- `TabBar`：AI / 网络 / 系统 / 应用 / 文件架五颗按钮（文件架跟着设置开关，`Page.visible(shelf:)`），只有图标（`Page.symbol`，名字在悬停提示里；左段 180pt 只放图标能放 6 颗，选中的带字就只能放 4 颗，试过加宽面板来放字，丑，退回）。页名补在页里：每页顶部一行 `PageTitle`——15pt 粗体页名 + 10pt 灰字摘要（`PageSummary` 纯函数：AI「3 个会话 · 1 个在等你」、网络「Wi-Fi en0 · ↓117 KB/s ↑49 KB/s」、系统「Apple M3 Max · 内存 18.4 / 48 GB」、应用「12 个在跑 · 5 个 Dock 里看不见」、文件架「2 项 · 保留 3 天」）；选中底 `white.opacity(0.18)` 的胶囊用 `matchedGeometryEffect` 在页签间滑动；顺序固定，不做拖拽。点页签写 `Preferences.lastPage`（只认四个 rawValue，别的回落 `ai`），启动时回到它。页内容切换不做过渡（试过按方向滑动加淡入淡出：窗口高度动画和页面滑动同时跑，每帧都要把新旧两页重新布局、曲线还不一样，看着卡，删了）；切页引起的高度变化用 0.2 s easeOut，开合才用 0.38 / 0.30 s 的 expo-out。
- 翻页手势由展开期间挂的本地事件监视器接（SwiftUI 列表会吃掉视图层的横向滚动）：两指横滑走 `SwipeTracker.feed`（只看 `phase`，`.began` 清零、`.changed` 累加，累计位移一跨过 40 且横向明显大于纵向就触发，一次手势只触发一次，`.cancelled` 不触发，纵向为主的是在滚列表不算；跨过就触发而不是等 `.ended`，因为快速轻扫的位移大半在无 phase 的 momentum 事件里，而无 phase 的事件一律不算——鼠标滚轮也是，Atoll 曾栽在 momentum 上让一次轻扫翻了两页）；三指轻扫走 `direction(fromSwipeDeltaX:)`。Δx < 0 → 下一页（自然滚动方向），到头不循环。事件原样放行，列表照常竖着滚。两指上下滑开合试过，真机上没人用，删了。

## 键盘

- ⌥⇧T（`HotKeyCenter`，Carbon `RegisterEventHotKey`，不要辅助功能授权）：收起就钉住展开到当前页，展开就收起。设置里可关；注册失败（别的 app 占了同一组合键）在开关下方红字提示。选 ⌥⇧ 是因为 ⌃⌥ 打头的组合常被代理类工具占用。
- ⌘,：面板展开时由本地键盘监视器接（只认 `event.window === panel` 的 ⌘,），设置窗口开着时走主菜单的「设置…」命令。不做全局 ⌘,，那会抢走别的 app 的这个键。
- 数字键 1–9：面板展开时切到第 N 个页签（按 `LaunchOptions.Page.visible(shelf:)` 数，超出的键吞掉不响）。设置「面板 → 键盘」可关，默认开。
- ⌘1–⌘5：面板展开时跳到 AI 页会话列表第 N 行的终端（和点那一行一样，走 `SessionJump.run`）。跳过去之后面板照旧开着，和点那一行一样，鼠标移出才收（终端被叫到前台，键盘跟着过去）；跳不成切到 AI 页，那一行红字说原因（失败原因按会话记在 `SessionJump.failures`，点行和按键共用）。设置里可关，默认开：它和浏览器、终端自己的 ⌘1–⌘5 同名，但只在面板展开时归面板，收起后照常给别的 app。
- 这几个键都在同一个本地键盘监视器里、按物理键位（`keyCode`）判，不看字符：输入法和键盘布局会改字符。判定是纯函数 `PanelKey.action`。不做全局：收起后数字和 ⌘N 照常打进原来的 app。

## 共用排版件（`Theme.swift`）

`Card(title, symbol, tint)`（圆角 12、底 `white.opacity(0.06)`、1pt 描边 `white.opacity(0.10)` 让卡片在黑底上有边、内边距 10；标题行是着色的 SF Symbol + 11pt 半粗白 0.8 文字，颜色按卡片固定：会话绿、用量蓝、吞吐橙、连接青、硬件蓝、电池绿、压力紫、应用薄荷绿）、`KeyValueRow(key, value, tint)`（11pt，值等宽数字右对齐）、`MetricBar(name, fraction, level, text, textWidth)`（条高 6、槽 `white.opacity(0.15)`、最短 4pt 让 0% 也有个点，`.ok` 绿 / `.warn` 黄 / `.critical` 红 / nil 中性）、`TabBar`、`HeaderButton`（标题行右侧的图标按钮，悬停出 `white.opacity(0.12)` 胶囊底）。数字一律 `Font.metric(size, weight)` = `design: .rounded` + `monospacedDigit`，只有三档：17 粗（速率）、13 半粗、11。可点的行（会话、应用）悬停底 `white.opacity(0.10)`。页内容 `padding(.horizontal, shoulder + 12)`，卡片间距 8。

## 设置窗口

`SettingsWindowController`：700 × 540、可竖向拉伸的普通窗口，打开时 app 切成常规激活策略（Toggle 才能接键盘和点击），关窗切回附件型；打开前先收起面板，否则被面板盖住——收起放在 `SettingsWindowController.show()` 里（`willShow`），不放在某个入口上：⌘, 在设置窗口已经是 key 时走的是主菜单的「设置…」，不经过面板的键盘监视器，原来只有面板入口收起面板，这条路上面板就一直盖在设置窗口前面（钉住面板 + 设置窗口开着时合成一次 ⌘, 复现过）。入口：面板齿轮、右键菜单、主菜单 / ⌘,、`--open settings`。

版式照 Atoll / 系统设置（`SettingsWindowView`）：`NavigationSplitView`，左边侧栏 `List(.sidebar)`，每行是带渐变底的 24pt 圆角方块图标 + 名字，七项分四组——「通用」「面板」不带组头，「功能」下「提示」「文件架」，「数据」下「hook」「用量」，「关于」单独在底部不带组头；右边是当前项的 `Form`（`.formStyle(.grouped)` 在根上设一次），每个开关一节、解释放节脚注。各项内容：

| 项 | 内容 |
|---|---|
| 通用 | 开机自启（写 `LaunchAgent` 再写 `Preferences`，失败显示原因）、⌥⇧T 开关（注册失败红字）、版本号与退出 |
| 面板 | 悬停展开；键盘（数字键 1–9 切页签、⌘1–⌘5 跳会话，都默认开）；标题行「保持唤醒」按钮；合盖也不休眠（含免密规则的装 / 撤）；截屏和共享屏幕时隐藏面板 |
| 提示 | 电池提示、点会话提示条时做什么（默认跳回对应终端）、摄像头 / 麦克风占用点；一行说明会话完成提示没有单独开关 |
| 文件架 | 开关、存放位置（在访达中显示）、已暂存几项、清空（[shelf.md](shelf.md)） |
| hook | 两侧 hook 行（状态 + 安装 / 移除，见 [hooks.md](hooks.md)） |
| 用量 | 四家提供方开关 |
| 关于 | 原「帮助」页：48pt 图标、「Tally」24pt、版本行读 `CFBundleShortVersionString`、「本应用由「郭快乐」个人开发并所有」、个人开发者及隐私声明（不列移植模块）；版本与作者之间显示 03 Q 版高达 Unicode 点阵（51 列 × 28 行）及「高达护航 · 用量有数」，图案等宽左对齐、整块居中，辅助功能用一句图案描述代替逐字符朗读；下面两段短说明：装 hook、卸载（面板怎么用、数据从哪来在界面上一看就知道，不写） |

开关的落点见 [monitors.md](monitors.md)。设置文件是 `~/Library/Application Support/Tally/preferences.json`，解码一律 `decodeIfPresent` 取默认；读失败记日志按默认值，写失败在「通用」顶部红字（内存里已改，重启会回到磁盘上的值）。

## 图标

`Resources/icons/make-icon.swift` 用 AppKit 画 1024 的计数刻线（深灰渐变底、四根白竖线、一根近似面板绿的斜线、macOS 圆角），出 iconset 十个尺寸再 `iconutil -c icns`，产物 `Resources/icons/AppIcon.icns` 进仓库：

```bash
swiftc Resources/icons/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources/icons
```

## 打包与安装

`Package.swift`：swift-tools 6.0，macOS 15，三个目标（`TallyKit` 共用库、`Tally` app、`TallyHook` hook 小程序）加测试目标，全部 `swiftLanguageMode(.v5)`。签名身份由 `TALLY_SIGN_IDENTITY` 决定，默认「Tally Dev」；钥匙串里没有这张证书就报错退出，不退回 ad-hoc：ad-hoc 每次编译都是一个新的代码身份，「允许 Tally 控制 <终端>」这类按身份记的授权会全部作废，重装一次就重新问一次。证书是自签的代码签名证书（钥匙串访问 → 证书助理 → 创建证书，自签名根 + 代码签名），叫别的名字就 `export TALLY_SIGN_IDENTITY="证书名"`。有了固定身份，授权跨重装有效（designated requirement 从「二进制哈希」变成「证书指纹」，`codesign -d -r-` 能看到）。证书不必设信任：`codesign` 照样能用它签，我们要的只是一个不变的身份。分发的 DMG 由 `build-dmg.sh` 强制重签成 ad-hoc——自签证书在别人机器上不受信任，验不过会被报「已损坏」，比 ad-hoc 的「无法验证开发者」更吓人；对方装一次之后授权同样记得住。

`scripts/build-app.sh` 组装 `build/Tally.app`（`Contents/MacOS/Tally` 与 `tally-hook`、`Info.plist`、`AppIcon.icns`、`pricing.json`），用上面的身份签名；`scripts/install.sh --build` 编译并装进 `/Applications`、清 quarantine、接管旧实例、把 LaunchAgent 指到新位置；`scripts/build-dmg.sh` 打分发镜像。`Info.plist`：`LSUIElement = true`（无 Dock 图标）、`CFBundleIdentifier = com.aiden.tally`、`NSAppleEventsUsageDescription`（定位终端要 Apple Events）。

## 验证

```bash
swift test --filter 'NotchGeometryTests|SwipeTests|PreferencesTests|NotchPanelTests|PeekTests|SubprocessTests'
./scripts/install.sh --build && sleep 3 && screencapture -R256,0,1000,60 -x /tmp/tally-closed.png
pkill -x Tally; while pgrep -x Tally >/dev/null; do sleep 0.5; done; open -a Tally --args --open ai && sleep 4 && screencapture -R256,0,1000,480 -x /tmp/tally-open.png
```

用例：闭合尺寸 1512 / 663 / 664 / 32 → 189 × 32、无刘海返回 nil、钉住点击只认刘海那段（刘海中央算、页签位置不算、刘海下方不算）、`openHeight` 三段夹紧、提示态宽随内容夹在刘海宽与上限之间、翻页阈值与方向、缩小宽限三态与屏幕顶边那一行算在面板里、页摘要文案、`lastPage` 非法值回落、面板按键（1–9 切页签只在开关开着且没按修饰键时、⌘1–⌘5 只在开关开着时、⌘, 恒有、别的组合不管）。截图：闭合态刘海两侧无边框；展开态居中、页签胶囊。手动：悬停展开、点外收起、⌥⇧T 展开再收起、展开时 ⌘, 开设置、两指横滑翻页；另外三条只能看实物、用真键盘验：

1. 展开面板按 2：切到网络页；按 ⌘1：跳到第一个会话的终端，面板照旧开着、鼠标移出才收，接着打字进的是那个终端；面板收起时按数字照常打进原来的 app。
2. 在任意 app 里打字，光标停到刘海等它展开，再移开继续打：字照常进原来的 app。
3. ⌥⇧T 钉住后点「网络」页签：切页，不收起；再点刘海中央才收。

提示条那条点击链路单测覆盖不到（`acceptsFirstMouse` 是事件投递层的事），只能手动走一遍，跑一轮交互会话让提示条落下之后：

1. 光标停在提示条上**一秒不动**——面板不该展开（悬停抑制生效）。
2. 点提示条——按设置里选的动作跳终端 / 展开到 AI 页；`log stream --predicate 'subsystem == "com.aiden.tally"' --level debug` 里不该有「从提示条跳回终端失败」。
3. 点完立刻 `lsappinfo front`——**仍然不该是 Tally**。`acceptsFirstMouse` 只影响首次点击的投递，不该破坏「面板永不抢激活」这条硬约束，这一步是专门验它的。
4. 电池提示条点一下——什么都不该发生（它不挂手势）。
5. 提示条自然到期收回后，光标不动，面板该在那一刻补起悬停展开。
