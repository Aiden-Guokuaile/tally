import AppKit

/// 贴在刘海上的面板。属性与 Atoll 的 `DynamicIslandWindow` 相同：
/// 无边框、不抢激活、盖在菜单栏之上、所有桌面和全屏应用里都在、不参与 ⌘` 循环。
final class NotchPanel: NSPanel {

    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        // 永远不开阴影：可见窗口上翻转 hasShadow 会重建窗口 surface，窗口服务器短暂认为光标不在窗口上，
        // AppKit 随即合成 mouseExited / mouseEntered，光标停在刘海上面板就会开、关、再开地闪
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    /// 全屏 app 里出不出现：带 `.fullScreenAuxiliary` 窗口服务器才让它进全屏空间，去掉就和普通窗口一样，全屏时整个面板不在。
    /// 不自己判「现在是不是全屏」：量窗口大小会把最大化的窗口当成全屏（codenotch 为此加了关掉的开关）。返回有没有变。
    @discardableResult
    func setShowsInFullScreen(_ show: Bool) -> Bool {
        var behavior = collectionBehavior
        if show { behavior.insert(.fullScreenAuxiliary) } else { behavior.remove(.fullScreenAuxiliary) }
        guard behavior != collectionBehavior else { return false }
        collectionBehavior = behavior
        return true
    }

    /// 展开态里的按钮要能收到点击，面板必须能成为 key window。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 弹系统模态 UI（`NSAlert` / `NSOpenPanel`）期间把面板压下去，`defer` 还原。
    ///
    /// `NSApplication.runModal` 在模态循环启动时把模态窗口的 level 钉死在 `.modalPanel`（8），
    /// 面板是 `.mainMenu + 3`（27），27 > 8，窗口服务器就把面板排前面——弹框在面板底下，
    /// 看不见也点不到。跟激活状态无关：模态中 `NSApp.isActive` 和 `isKeyWindow` 都是真，照样在后面。
    ///
    /// 只能压面板，不能抬弹框：`runModal` 之前设 level 会被 AppKit 踩回 8，`addChildWindow` 同样被打散；
    /// 而且压面板连别的进程呈现的面板（AirDrop 那种）也一并救得了。
    @MainActor
    static func steppingAside<T>(_ body: () -> T) -> T {
        let panels = NSApp.windows.compactMap { $0 as? NotchPanel }
        let levels = panels.map(\.level)
        for panel in panels { panel.level = .normal }
        defer { for (panel, level) in zip(panels, levels) { panel.level = level } }
        return body()
    }
}
