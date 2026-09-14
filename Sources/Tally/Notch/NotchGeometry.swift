import AppKit

/// 一块屏幕里算刘海面板要用到的四个数。单独抽出来是为了测试能手工构造。
struct ScreenMetrics: Equatable {
    var frame: CGRect
    var auxiliaryTopLeftWidth: CGFloat
    var auxiliaryTopRightWidth: CGFloat
    var safeAreaTop: CGFloat

    init(frame: CGRect, auxiliaryTopLeftWidth: CGFloat, auxiliaryTopRightWidth: CGFloat, safeAreaTop: CGFloat) {
        self.frame = frame
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
        self.safeAreaTop = safeAreaTop
    }

    init(screen: NSScreen) {
        self.init(
            frame: screen.frame,
            auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
            auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width ?? 0,
            safeAreaTop: screen.safeAreaInsets.top
        )
    }
}

/// 刘海面板的尺寸与位置，全是纯函数。
///
/// 闭合态的算法来自 Atoll 的 `getClosedNotchSize`：屏幕总宽减去刘海两侧的可用区域，
/// 再加 4pt 盖住刘海边缘的圆角缝。本机 14 寸实测：1512 − 663 − 664 + 4 = 189，高 32。
enum NotchGeometry {

    /// 宽度固定：两侧各 `shoulder` 被肩部弧线占掉，标题行中间给刘海留空后左右各约 180pt——左边放得下 6 颗只有图标的页签，右边 5 颗按钮已满。
    static let openWidth: CGFloat = 620
    /// 展开态顶角向外翻的肩部弧线半径，竖边向内缩这么多；闭合态为 0，和刘海齐平。
    static let shoulder: CGFloat = 19
    /// 底角半径：闭合 12 盖住刘海圆角缝，展开 24。
    static let closedBottomRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 24
    /// 顶栏、页签、内边距加起来的固定高度。
    static let chrome: CGFloat = 56
    static let minOpenHeight: CGFloat = 160
    /// 提示态：从刘海往下垂一条（照 Atoll 的 sneak peek 标准式），宽度跟着内容走：最窄和刘海一样宽，最宽 `peekMaxWidth`。
    static let peekDrop: CGFloat = 46
    static let peekBottomRadius: CGFloat = 18
    static let peekMaxWidth: CGFloat = 420
    /// 内容两侧的留白。
    static let peekPadding: CGFloat = 12

    /// 展开态高度 = 固定部分 + 当前页内容的自然高度，夹在下限与屏幕高的六成之间；超过上限页内容才滚。
    static func openHeight(content: CGFloat, screenHeight: CGFloat) -> CGFloat {
        min(max(content + chrome, minOpenHeight), (screenHeight * 0.6).rounded())
    }

    /// 没有刘海（`safeAreaTop <= 0`）返回 nil。
    static func closedSize(_ m: ScreenMetrics) -> CGSize? {
        guard m.safeAreaTop > 0 else { return nil }
        let width = m.frame.width - m.auxiliaryTopLeftWidth - m.auxiliaryTopRightWidth + 4
        return CGSize(width: width, height: m.safeAreaTop)
    }

    /// 展开态标题行中间给物理刘海留的空位：闭合宽再各留 4pt 余量。页签在它左边、按钮在它右边，都不会钻到刘海底下。
    static func headerGap(closedWidth: CGFloat) -> CGFloat {
        closedWidth + 8
    }

    /// 钉住时这一下点在不在刘海上（窗口坐标，原点在左下）：顶部 `notch.height` 高，横向在标题行给物理刘海留的空位里。
    /// 面板里每次左键都会经过 `NotchHostView.mouseDown`，不按位置判的话点页签也会把钉住的面板收起。
    static func hitsNotch(_ point: CGPoint, panelSize: CGSize, notch: CGSize) -> Bool {
        point.y >= panelSize.height - notch.height && abs(point.x - panelSize.width / 2) <= headerGap(closedWidth: notch.width) / 2
    }

    /// 提示态：宽 = 内容宽 + 两侧留白，夹在刘海宽和上限之间；高 = 闭合高 + `peekDrop`。
    static func peekSize(closed: CGSize, content: CGFloat) -> CGSize {
        CGSize(width: min(max(content + 2 * peekPadding, closed.width), peekMaxWidth), height: closed.height + peekDrop)
    }

    /// 把一个尺寸钉在屏幕顶部中央。AppKit 坐标原点在左下，所以 y 用 maxY 往下减。
    static func frame(for size: CGSize, on m: ScreenMetrics) -> CGRect {
        CGRect(
            x: m.frame.midX - size.width / 2,
            y: m.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// 带刘海的内建屏。接外接屏时 `NSScreen.main` 可能是外接屏，所以按硬件属性找。
    static func builtInNotchScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0 && screen.safeAreaInsets.top > 0
        }
    }
}
