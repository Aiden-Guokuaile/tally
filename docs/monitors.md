# 常驻监听与小工具

> 面板之外、跟着设置开关起停的几样：保持唤醒、电池事件、摄像头 / 麦克风占用、截屏隐藏、文件架。关掉的一样不起监听、不占内存；开关在设置窗口的「面板」「提示」「文件架」三项里（悬停展开见 [panel.md](panel.md)）。

## 起停

`PreferencesStore.prefs` 每次写入都调 `onChange`，`NotchController.applyPreferences()` 据此起停：幂等，页签切换写 `lastPage` 也会触发，无妨。各开关的落点：

| 开关 | 开 | 关 |
|---|---|---|
| 标题行「保持唤醒」按钮 | 标题行右段多一颗杯子，系统页多一张「保持唤醒」卡片 | 两个都不画；开着的断言立刻释放，否则机器一直醒着却没有地方关 |
| 接电 / 拔电 / 低电 / 充满时提示 | `BatteryWatcher` 挂电源通知 | 摘掉 run loop source |
| 摄像头 / 麦克风被占用时画点 | `PrivacyWatcher` 挂设备属性监听 | 全部摘掉，状态清零 |
| 截屏和共享屏幕时隐藏面板 | `panel.sharingType = .none` | `.readOnly`（可见态是它，不是 `.none`）。默认关：截图验证流程要能拍到面板 |
| 「文件架」页 | 多一颗页签，面板根视图注册文件拖放 | 页签没了、拖放不注册、索引与缩略图放掉；磁盘上的副本不动（[shelf.md](shelf.md)） |
| 「合盖也不休眠」胶囊 | `sudo -n pmset -a disablesleep 1`（第一次要先装免密规则，输一次密码） | 立刻抹回 0，不弹框；退出 app、保持唤醒到期同样抹回 |

## 保持唤醒（`KeepAwake`）

就是 `caffeinate` 的按钮版：一个 IOKit 电源断言，「屏幕也保持常亮」（`Preferences.keepAwakeDisplay`，默认开，和 `caffeinate -dims` 的习惯一致）勾着是 `kIOPMAssertionTypePreventUserIdleDisplaySleep`（等于 `-d`，屏幕常亮系统自然也不睡），不勾是 `kIOPMAssertionTypePreventUserIdleSystemSleep`（等于 `-i`，只挡系统闲置休眠，屏幕照常黑）；不用 `NoDisplaySleep`，那个名字 10.7 起标了废弃（`pmset` 里两者登记的都是 `PreventUserIdleDisplaySleep`，效果一样）；`-s`（接电时不休眠）两者都覆盖，`-m`（磁盘）Apple Silicon 上没意义。断言归 Tally 进程所有，进程退出内核自动释放，不需要退出钩子；`start` 先 `stop` 再建，永远只有一个；开着时切换屏幕常亮换一种断言、到期时刻不变（`setKeepsDisplay`）。时长 15 / 30 分钟、1 / 2 / 4 小时、一直，外加一档自定义（`Preferences.keepAwakeCustomMinutes`，15 分钟到 24 小时、15 分钟一步，默认 90 分钟）：定时的用一个 `Timer` 到点释放，不限时不起任何定时器。自定义档只在系统页卡片上设（面板不抢激活，指望不上输入框，所以是 `−  1 小时 30 分  +` 的步进，见 [system.md](system.md)）；设过之后标题行右键菜单里也多这一条。

状态落盘（`keepAwakeActive` / `keepAwakeUntil` / `keepAwakeMinutes`），启动时 `restore()` 接回来：断言随进程死，装个新版本就没了，人只会看到「点了杯子屏幕还是黑」。到期的直接清掉。

标题行按钮：点一下不限时开 / 关，右键菜单选时长、勾「屏幕也保持常亮」；开着时杯子实心橙色，悬停提示「保持唤醒到 HH:mm · 屏幕常亮」之类。右键菜单里「一直保持唤醒」和五个时长档都带勾（`Toggle` 不是 `Button`）：勾落在当前那档上，不限时勾「一直」，点已经勾着的那条就是关闭。原来这几条是 `Button`，天生不显示状态，于是「杯子亮着但菜单里一个勾都没有」，人只能靠杯子颜色和悬停提示反推。档位存在 `KeepAwake.minutes` 里，落盘 `keepAwakeMinutes`：`until` 只是到期时刻，反推不出当初选的是哪档（选 1 小时过了 10 分钟就成了 50 分钟），重装之后勾会跑。

### 合盖也不休眠（`LidSleepBlocker`）

**电源断言挡不住合盖。** 断言只挡*闲置*休眠；合盖触发的是 clamshell 休眠，低一层，`caffeinate -d/-i/-s` 和任何 `IOPMAssertion` 都拦不住——没接外接屏时合盖必睡。不接外接屏还要合盖继续跑，只有一个开关：内核的 `SleepDisabled`，即 `pmset -a disablesleep 1`，要 root。

这是保持唤醒的**附加开关**（默认关，不落盘），开的时候如果保持唤醒还没开就一起开（`SleepDisabled` 只挡合盖，闲置休眠仍旧归断言管）；关保持唤醒时它一起关。

**拿 root 的方式只有免密规则这一条。** 第一次开的时候往 `/etc/sudoers.d/tally` 装一条 NOPASSWD 规则，只放行三条命令——`pmset -a disablesleep 1`、`pmset -a disablesleep 0`、`rm -f /etc/sudoers.d/tally`（最后一条是为了撤销时也不用输密码，放行删掉自己的授权不扩大任何权限）。装的时候先写临时文件、`visudo -cf` 验过语法再 `install -m 440 -o root -g wheel` 到位，任何一步失败都不留半条规则——写坏 sudoers 会把整个 `sudo` 搞挂。输一次密码，之后跨重启、跨重装都不再问。装没装以 `sudo -n -l <命令>` 的实际结果为准，不看文件在不在：规则生效还得 sudoers 真的 include 了那个目录。

> **为什么不能「每次开走一次授权、顺带在授权里起个 root 看门狗负责恢复」**：`do shell script … with administrator privileges` 里起的后台进程**当场就被杀**。实测：`echo $!` 把 pid 记下来了，几秒后进程不存在，那个每秒写一行的探针一行都没写出来（同一段脚本在普通 shell 下四条恢复路径全部正常，所以不是脚本的问题）。于是「关掉开关 / 退出 app 自动恢复」全是哑的——界面显示关了，系统里那个开关还开着，机器再也不休眠。这不是理论风险，是真踩过：`/Library/Preferences/com.apple.PowerManagement.plist` 上一次写入停在开启那一刻，之后 26 分钟没有任何恢复写入。

有了免密就不需要看门狗了，Tally 自己置位、自己恢复：开 → `sudo -n pmset -a disablesleep 1`；关、保持唤醒到期、退出 app（`applicationWillTerminate`）→ `sudo -n pmset -a disablesleep 0`。全程不弹框。

唯一恢复不了的路是 Tally 被 `SIGKILL` 或断电：`SleepDisabled` 是持久设置，重启也留着。所以启动时 `checkResidue()` 读一次 `pmset -g`，是 1 而不是这一轮开的就**直接抹掉**（免密，不弹框）；没有免密规则可用时才在卡片上出一行橙字加一颗「恢复」胶囊（点它要一次密码）。Tally 是登录项，这个窗口最长到下次登录。

界面上写清两条代价：合盖装进包里机器还在跑，会发热；**合盖也不再锁屏**——锁屏是跟着休眠触发的，不睡就没有锁的时机（真机实测：合盖 60 秒再打开，`pmset -g log` 里零条睡眠事件，直接回到桌面没有登录窗），要带着走得先按 ⌃⌘Q 锁一下再合。默认关，开着时卡片上那颗胶囊填橙色。

选时长的正经地方是系统页的「保持唤醒」卡片（[system.md](system.md)）：杯子只有 24 × 22pt，还得先悬停展开刘海再右键，两步都要瞄准。杯子留着当快捷开关和状态灯。档位文案两处共用 `KeepAwake.durationLabel(_:)`。设置窗口「面板」的「保持唤醒」一节有三条：**「现在保持唤醒」才是真开关**（原来这节只有「屏幕也常亮」，它只挑模式不启动，勾了以为开了、屏幕照黑，这是个 bug）、「屏幕也常亮」、「标题行按钮」；开着时下面一行显示到几点。

## 电池事件（`BatteryWatcher` + `BatteryRule`）

`IOPSNotificationCreateRunLoopSource` 挂在主 run loop 上，电源状态一变就回调（事件驱动，不轮询），每次回调重读一次 `BatteryHealth.read()`（IOKit 注册表，和系统页同一来源）。`BatteryRule.event(previous:current:warned:)` 纯函数比上一次和这一次：

| 跃迁 | 事件 | 提示条里 |
|---|---|---|
| `externalConnected` 假 → 真 | `pluggedIn`，并清空 `warned` | 绿闪电弹跳「续命成功 80%」「电池：谢谢投喂」 |
| `externalConnected` 真 → 假 | `unplugged` | 黄插头下弹「断奶了 80%」「电池：靠自己了，问题不大」（< 50% 是「有点虚」） |
| 没接电源且跌到 ≤ 20% / ≤ 10%，该阈值这次放电没报过 | `low(percent, threshold)`，一次跨过两个阈值只报最低的，两个都记已报 | 橙「饿了 19%」「电池：给口吃的」；红「要昏了 9%」「电池：救命」 |
| 接着电源，`state` 变成已充满 | `full` | 绿电池弹跳撒星「吃饱了 100%」「电池：拔吧，撑着了」 |

文案是拟人那套（把电池当成会说话的小家伙）；备选还有打游戏（「回血中 / 离线模式 / 残血 / 濒死 / 满血」）和航天（「对接成功 / 脱离母舰 / 燃料告急 / 燃料见底 / 加注完成」），换一套只改 `Peek.battery`。

接拔电看 `externalConnected` 不看 `state`：优化充电把电量停在 80% 时接着电源但没在充，`state` 是「接电源」而不是充电，拔掉前后按 `state` 判没有跃迁——第一版就是这样漏掉了拔电提示。
| 第一次读数 | 不报 | |

低电模式的变化 `IOPS` 不通知，也不做。事件交给 `NotchController.showPeek(.battery(_:))`，外观与会话完成提示相同（[panel.md](panel.md) 的「提示」）。

## 摄像头 / 麦克风占用（`PrivacyWatcher`）

只读设备的 `DeviceIsRunningSomewhere` 属性，不开流，所以不要权限、不弹授权框（Info.plist 也没有摄像头 / 麦克风用途描述，真要开流会被系统杀）。

- 麦克风：`kAudioHardwarePropertyDevices` 列出所有设备，留有输入流（`kAudioDevicePropertyStreams` 输入 scope 非空）且有 `kAudioDevicePropertyDeviceIsRunningSomewhere` 属性的，每个都挂 `AudioObjectAddPropertyListenerBlock`；另在系统对象上监听设备列表，热插拔后重挂。比只盯默认输入设备（Atoll 的做法）多覆盖「用非默认设备录音」。
- 摄像头：`kCMIOHardwarePropertyDevices` 列出所有设备，留有输入流的，挂 `CMIOObjectAddPropertyListenerBlock`；同样监听设备列表。虚拟摄像头（OBS 之类）也算设备。
- 任一设备报占用就亮：展开态标题行右段画一个 `video.fill` 绿 / `mic.fill` 橙（闭合态不画东西，刘海底下没有像素）。
- 已知：蓝牙耳机偶尔在没人录音时也报占用，接受。

## 验证

```bash
swift test --filter 'BatteryRuleTests|KeepAwakeTests|LidSleepBlockerTests|PrivacyWatcherTests|PreferencesTests|SwipeTests'
pmset -g assertions | grep -i tally     # 点了杯子之后应有一行 Tally：保持唤醒，勾了屏幕常亮是 PreventUserIdleDisplaySleep
pmset -g | grep -i sleepdisabled        # 开了「合盖也不休眠」是 1；关掉后 5 秒内这一行消失
```

用例：电池规则五条（首读不报、接拔电、阈值每次放电只报一次且一次跨两个只报最低、充满只在充电之后）、断言起停（定时有到期时刻、不限时没有、重复 stop 无害）、自定义档能落盘且右键菜单的勾落在它上面、步进夹在 15 分钟到 24 小时之间、免密规则文本（三条命令逐字、先 `visudo -c`、验不过连临时文件一起收）与 `pmset -g` 的 `SleepDisabled` 解析、真机挂上内建麦克风与摄像头各 ≥ 1 且关掉清零（没设备跳过）、六个开关缺键取默认且截屏隐藏默认关、提示映射。手动：合盖前点杯子看 `pmset`；第一次开「合盖也不休眠」输一次密码，之后 `sudo -n -l /usr/bin/pmset -a disablesleep 1` 退出码是 0、`pmset -g | grep -i sleepdisabled` 是 1，合盖十分钟再打开机器没睡（`pmset -g log | grep -i sleep` 里没有 clamshell 休眠）；关掉立刻回 0 且**不再弹框**，再开也不弹；`pkill -x Tally` 之后回 0；`pkill -9 -x Tally` 会留下 1，下次启动 Tally 自动抹掉；设置里取消「免密规则」后那条 `sudo -n -l` 又变成非 0；拔电源看提示条；开 FaceTime 展开面板看标题行的绿点；设置里关「截屏隐藏」再截图能拍到面板、开了拍不到。
