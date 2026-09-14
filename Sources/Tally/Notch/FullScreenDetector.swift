import AppKit

/// 内建屏上现在是不是有别的 app 在系统全屏。只读窗口列表（位置、层级、属于哪个进程），不要屏幕录制和辅助功能权限。
///
/// 不能靠去掉 `.fullScreenAuxiliary` 让窗口服务器替我们藏：面板带着 `.canJoinAllSpaces`，光这一条就会进全屏空间
/// （macOS 26.2 实测，去掉那个标记的面板在全屏里照样在屏上），而「每个桌面都在」离不开它。
/// 也不能只看有没有铺满屏幕的窗口：最大化的窗口和全屏窗口位置一模一样（实测都是 0,33,1512,949）。
/// 全屏时那个 app 还会在刘海那条带子上多一个窗口（实测层级 26、0,0,1512,33），最大化时没有——两样都有才算。
enum FullScreenDetector {

    struct Window: Equatable {
        let pid: pid_t
        let layer: Int
        /// CG 全局坐标（原点在主屏左上角），和 `CGDisplayBounds` 同一套。
        let bounds: CGRect
    }

    /// 纯函数。`display` 是内建屏的 `CGDisplayBounds`，`safeTop` 是刘海高。
    static func isFullScreen(windows: [Window], display: CGRect, safeTop: CGFloat, selfPid: pid_t) -> Bool {
        let slack: CGFloat = 2
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= slack }
        // 铺满内建屏（上边可以让出刘海那条）的普通层窗口，记下是哪个进程的
        let covering = Set(windows.filter { window in
            window.pid != selfPid && window.layer == 0
                && near(window.bounds.minX, display.minX) && near(window.bounds.width, display.width)
                && near(window.bounds.maxY, display.maxY) && window.bounds.minY <= display.minY + safeTop + slack
        }.map(\.pid))
        guard !covering.isEmpty else { return false }
        // 同一个进程在刘海那条带子上还有一个更高层的窗口，才是全屏
        return windows.contains { window in
            covering.contains(window.pid) && window.layer > 0
                && near(window.bounds.minX, display.minX) && near(window.bounds.minY, display.minY)
                && near(window.bounds.width, display.width)
                && window.bounds.height > 0 && window.bounds.height <= safeTop + slack + 1
        }
    }

    /// 读当前在屏上的窗口判内建屏。一次 0.3 ms 上下（实测 21 个窗口），只在切桌面、切 app 时调，不进 100 ms 的悬停轮询。
    static func current(on screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            // 读不到就当没全屏（面板照常显示，不会藏着回不来），但得留一笔：不然「全屏隐藏不管用」查不出是读不到还是真没全屏
            Log.error("读不到窗口列表，判不了全屏，面板照常显示")
            return false
        }
        let windows = list.compactMap { info -> Window? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let raw = info[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary)
            else { return nil }
            return Window(pid: pid, layer: layer, bounds: bounds)
        }
        return isFullScreen(windows: windows, display: CGDisplayBounds(number.uint32Value), safeTop: screen.safeAreaInsets.top, selfPid: getpid())
    }
}
