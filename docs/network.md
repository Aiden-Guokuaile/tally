# 「网络」页

> 第一行「吞吐」「连接」两张卡片人人都有；第二行「代理」卡片只在有代理软件在跑、系统代理开着或有 TUN 网卡时出现。全部本地读，不向外网发请求。

## 吞吐

`InterfaceSampler.counters()`：`getifaddrs` 里名字以 `en` 开头（Wi-Fi、以太网、雷雳）的 `AF_LINK` 条目的 `if_data.ifi_ibytes / ifi_obytes` 之和；`utun*` 不计入，它的流量最终还是从 en0 出去，加上会翻倍。计数是 32 位会绕，差分用 `&-`（一秒内超过 4 GB 才会错）。`NetworkStore` 每秒差分一次：还没量到是 nil（显示「—」），某一秒取不到就保持上一秒；最近 60 秒进 `history` 画折线（`HistoryGraph`：下行绿、上行蓝，各自 1.5pt 线加从 0.3 到 0.05 的渐变面，按窗口内峰值缩放，不满 60 个点靠右）。速率与容量格式 `ByteFormat`：1024 进制四档，KB 以上一位小数、小数为 0 不带。

## 连接

`InterfaceSampler.primary()`：SystemConfiguration `State:/Network/Global/IPv4` 的 `PrimaryInterface` 与 `Router`，IPv4 从 `getifaddrs` 的 `AF_INET` 条目取；`dns()` 读 `State:/Network/Global/DNS`；`wifi(interface:)` 用 CoreWLAN 取 rssi / 噪声 / 速率 / 信道（这些不要权限；SSID 从 macOS 14 起要定位权限，所以不读）。三行：「Wi-Fi en0 · -37 dBm」或「有线 en0」、「本机 192.168.x.x · 网关 …」、「DNS …」；没有主接口整行「—」。`start()` 时立刻取，之后每 10 秒。

## 代理卡片

出现条件：认出了代理软件，或系统代理（HTTP / HTTPS / SOCKS 任一）开着，或有 up 且带 IPv4 的 `utun*`（TUN 或 VPN，系统自带的 utun0…3 只有 IPv6 链路本地地址）。系统代理读 `SCDynamicStoreCopyProxies`（`parseProxies(_:tunActive:)` 纯函数，`XxxEnable` 为 0 或主机为空算关）。

标题行只有「[图标] 软件名」+ 右侧「打开 ▸」，卡片任何地方单击也打开；没认出软件时软件名写「代理」，没有「打开」。端口 / TUN / 模式降到第二行，一项一个小标签：`HTTP 127.0.0.1:7899`、`TUN 开`、`模式 rule`（没有内核接口时是 `TUN 有`）。原来这些和软件名用「·」串成一条长文本挤在标题行里，12pt 一长条扫不出哪段是哪段。图标取运行中程序自己报的 `NSRunningApplication.icon`（和 ⌘Tab 一致），拿不到退回包里的文件图标。

### 代理软件怎么认（`ProxyAppDetector`）

1. 系统代理指向本机（127.0.0.1 / localhost / ::1）的端口时，`lsof -nP -iTCP:<端口> -sTCP:LISTEN -Fp` 拿监听 pid（几十毫秒，10 秒一次放后台，stderr 丢弃、3 秒超时）；指向别的主机不反查。
2. 从那个 pid 沿父进程走（`SysctlProcessTable`，最多 8 层），直到某个 pid 是 `NSRunningApplication`（内核常是 app 的子进程）；走到的是终端或编辑器（命令行代理从里面启动的）就当没认出。
3. 没认出再看已知名单里有没有在跑的：Watchdog、ClashX、ClashX Meta、Clash Verge、mihomo-party、Surge、V2rayU、ShadowsocksX-NG。
4. 打开：`NSWorkspace.openApplication(at: bundleURL)`，会激活并触发 reopen，菜单栏 app 通常会弹主窗口；失败记日志。

后台反查带轮次编号，收起面板时取消，晚回来的不改状态。

### 可选：mihomo 内核接口

`MihomoClient.defaultSocketPath`（`/tmp/gauge/core.sock`）存在时，每 10 秒向它 `GET /configs` 与 `/proxies`（Unix socket 上的极简 HTTP/1.1，chunked 解码，按行交付，8 秒读超时），标签行多出模式与 TUN，下面各组两列排（`Selector` 类型、去掉 GLOBAL、按 `GLOBAL.all` 的次序最多 6 个）；两列不是三列是因为三列每格只剩 200pt，节点名一长就贴边，组名再给个 56pt 最小宽度，同一列的节点名才对得齐（比它长的照常撑开，不截断）。两个请求一起判：任一失败显示「代理内核没有响应」，下一个 10 秒周期自然重试；发新一轮前先作废上一轮（回调带轮次编号），慢响应不会拿旧数据盖新数据。这个 socket 是作者的代理客户端 Watchdog 暴露内核控制接口的位置；别的 mihomo 客户端走 TCP 9090 + secret，不接，它们的卡片只有系统代理那几行。socket 不存在时整段不出现，其余功能不受影响。

只读：不切节点、不改模式、不开关 TUN。

## 验证

```bash
swift test --filter 'InterfaceSamplerTests|NetworkStoreTests|ProxyAppDetectorTests|MihomoClientTests|ChunkedDecoderTests'
pkill -x Tally; while pgrep -x Tally >/dev/null; do sleep 0.5; done
open -a Tally --args --open network && sleep 8 && screencapture -R256,0,1000,480 -x /tmp/tally-network.png
ipconfig getifaddr en0; route -n get default | grep gateway; scutil --dns | grep -m1 nameserver; scutil --proxy | grep -E 'HTTPProxy|HTTPPort'
```

用例：环绕减法、`parseProxies` 开 / 关 / 缺键、`localPort` 只认本机、父进程回溯、名单命中、`listeningPid` 与 lsof 一致、Store 的历史封顶与 stop 清空、没有 socket 不发请求、任一失败置没响应、作废轮次不生效；客户端对着测试里起的真 Unix socket 服务端验 Content-Length 尾巴、chunked 切行、非 2xx、超时。截图：连接卡片与上面四条命令一致；有代理软件时第二行有图标、名字、「打开 ▸」。真机用例在没网 / 没 Wi-Fi 时跳过。
