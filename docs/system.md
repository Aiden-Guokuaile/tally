# 「系统」页

> 「硬件」「电池」并排，下面「保持唤醒」「压力」：内存 / CPU / 磁盘三条 + 内存大户。全走公开 API，只在停在这页时每 2 秒采一次。

## 硬件（一次性，`HardwareInfo.read()`）

「Apple M3 Max · 16 核 · 48 GB」「macOS 26.2 · 已开机 1 天 14 小时」。芯片 `machdep.cpu.brand_string`；核心 `hw.perflevel0.physicalcpu` + `hw.perflevel1.physicalcpu`（Intel 没有能效核就用 `hw.physicalcpu`）；内存 `hw.memsize`；版本 `ProcessInfo.operatingSystemVersion`（补丁号非 0 才带）；开机 `kern.boottime`，文案满一天「1 天 13 小时」、不满一天「13 小时 5 分钟」、不满一小时「5 分钟」。第一次展开时读，标题行 ↻ 重读。

## 电池（`BatteryHealth.read()`）

IOKit 注册表 `AppleSmartBattery`（`ioreg` 就能看，不是私有 API）：电量 `CurrentCapacity`（Apple Silicon 上本身是百分比）、状态（`IsCharging` → 充电中；插电且不充电：≥ 95% 已充满、否则「接电源」——优化充电停在 80% 就是这样；没插电放电）、最大容量取「系统信息 → 电源」的同一个数（叫法也跟它：系统里 93% 那栏就叫「最大容量」，「健康度」是另一项文字状况——正常 / Normal，两个混在一起会有歧义）（`system_profiler -xml SPPowerDataType` 的 `sppower_battery_health_maximum_capacity`，0.15 秒，只在打开这一页时读一次，后台读不挡主线程）；取不到才退回 `AppleRawMaxCapacity ÷ DesignCapacity`。不直接用比值是因为对不上：本机 ioreg 算出来 89%（`NominalChargeCapacity` 那版 91%），系统显示 93%——系统那个数是平滑过的，不是这两个字段的直接比值、循环 `CycleCount`。一行「79% 放电 · 健康 89% · 循环 134 次」，读不到的项「—」；没电池显示「无电池」。颜色：接着电源（充电中 / 已充满 / 接电源）一律绿，放电 ≤ 10% 红、≤ 20% 黄；健康 ≥ 80% 绿、≥ 60% 黄、其余红。不做温度（字段单位机型不一）、风扇、GPU（私有接口）。

电池卡片第二行是废纸篓，见下。

## 保持唤醒（`KeepAwakeCard`）

机制在 [monitors.md](monitors.md)，这里只说这张卡片。第一行七个胶囊「一直 / 15 分钟 / 30 分钟 / 1 小时 / 2 小时 / 4 小时 / 自定义」，当前那档填橙色，点一下就切到那档；开着时右端多一颗「关闭」。第二行左边是状态（「一直开着，直到手动关闭」/「到 14:30 自动关闭」/「关着，Mac 闲置一会儿就会休眠」），右边两颗胶囊「合盖也不休眠」「屏幕也常亮」，后者亮着就是 `caffeinate -d`。

「自定义」那颗点一下不直接启动，而是在卡片底下展开一行 `−  1 小时 30 分  +` 加一颗「开始」：面板不抢激活，输入框指望不上，所以用步进，15 分钟一步、夹在 15 分钟到 24 小时。「开始」之后这行收起，胶囊文字变成设好的时长（`Preferences.keepAwakeCustomMinutes` 记住它），下次点它还是展开这行——一个进入点做「设一个自定义时长」这一件事，不用去猜点一下是设还是启动。

「合盖也不休眠」动的是系统级的 `SleepDisabled`，第一次开要装一条免密规则、输一次密码，之后开关都不弹框（机制、自动恢复与残留处理都在 [monitors.md](monitors.md)）；它开着时下面多一行小字提示合盖会发热。上一轮被强杀留下的残留，在没有免密规则可用时出一行橙字加一颗「恢复」胶囊。

为什么在这页而不是只留标题行那颗杯子：杯子的命中区只有 24 × 22pt（`Theme.swift` 的 `HeaderButton`），还要先悬停展开刘海再右键，选时长两步都得瞄准。杯子留着当快捷开关和状态灯（实心橙 = 开着），选时长来这儿。设置里关掉「标题行「保持唤醒」按钮」时这张卡片一起不画——那个开关关掉整个功能，留着控件会点了没反应。

## 压力（`SystemSampler`，每 2 秒）

| 项 | 来源 | 颜色 |
|---|---|---|
| 内存 | `host_statistics64`：已用 = (active + wired + compressed) × 页大小，和活动监视器口径一致；后面跟内核的压力等级 `kern.memorystatus_vm_pressure_level`（1 正常、2 偏紧、4 严重） | 已用 ≥ 90% 红、≥ 75% 黄 |
| CPU | `host_processor_info` 两次采样的 tick 差分（所有核汇总），第一次为 nil | ≥ 90% 红、≥ 70% 黄 |
| 磁盘 | 系统卷 `volumeAvailableCapacityForImportantUsage` / `volumeTotalCapacity` | 可用 < 10% 红、< 20% 黄 |
| 交换 | `vm.swapusage`，用了才显示 | 中性 |
| 内存大户 | `proc_listallpids` + `proc_pid_rusage` 的 `ri_phys_footprint`，前三名列表；名字是纯版本号且路径含 `/claude/` 的显示「claude」，读不到名字显示「pid N」 | — |

每项各自失败互不影响，采不到显示「—」。数值格式「已用 17.4 / 48 GB · 正常」（两边单位相同只写一次）。

## 废纸篓（`TrashInfo`）

只看 `~/.Trash`，不碰外接盘的 `.Trashes` 和 iCloud。`scan()` 在后台枚举：顶层可见项数 + 递归已分配大小，展开时和清空后各扫一次（后台任务带轮次编号，晚回来的不盖新的）。一行「废纸篓 118 MB · 25 项」+「清空」胶囊按钮（空时禁用）：先 `NSAlert`「清空废纸篓？将永久删除 N 项（大小），不能撤销。」（包在 `NotchPanel.steppingAside` 里，否则弹框被面板盖住，见 [panel.md](panel.md)），确认后逐个顶层项 `removeItem`（含隐藏文件，某项失败记日志继续），走 FileManager 不走 Finder，所以不弹「想控制 Finder」的授权；完成后按钮旁绿字 4 秒「已清空 N 项」（有失败「删了 N 项，M 项失败」）。

## 验证

```bash
swift test --filter SystemSamplerTests
pkill -x Tally; while pgrep -x Tally >/dev/null; do sleep 0.5; done
open -a Tally --args --open system && sleep 7 && screencapture -R256,0,1000,480 -x /tmp/tally-system.png
sysctl -n machdep.cpu.brand_string hw.memsize kern.memorystatus_vm_pressure_level; uptime; du -sh ~/.Trash
ioreg -r -c AppleSmartBattery | grep -E '"(CycleCount|DesignCapacity|AppleRawMaxCapacity|CurrentCapacity)"'
```

用例：CPU 差分公式、四项颜色阈值、`ByteFormat` 四档与去零、压力等级映射、电池三态与健康百分比、开机时长三档文案、核心与版本文案、真实采样的芯片与内存总量等于 `sysctl` 命令输出、内存大户前三非空且降序、`TrashInfo` 在临时目录上扫与清。截图：硬件两行、电池两行、压力三条带「· 正常」、内存大户三行，一屏放下不滚。
