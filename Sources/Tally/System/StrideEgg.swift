import AppKit

/// 恐龙右边那颗窝里的花斑蛋：从下往上填到内存已用的高度，颜色档见 `StrideRule.eggTone`（70% 起橙、85% 起红并裂开）。
/// 和恐龙帧拼成一张 47 × 18pt 的图给状态栏按钮。蛋的坐标沿用 Stride 画布的约定：单位 pt、原点左上、y 朝下。
enum StrideEgg {

    /// 恐龙帧 34pt 宽，蛋和草窝占右边 13pt。
    static let size = NSSize(width: 47, height: 18)

    /// 帧图（68 × 36px）拼上蛋，画成 94 × 36px 的 @2x 位图。调用方按蛋的样子缓存，换帧不现画。
    static func compose(frame: CGImage, memory: Double, dark: Bool) -> NSImage? {
        let scale: CGFloat = 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if dark {
            // 深色模式的菜单栏常被壁纸染成中灰蓝（实测 #5c76b4、#687f9f，不是纯黑），橙、红、草窝跟它的亮度对比只有 1.2–2，
            // 整张图（恐龙 + 蛋）描一圈暗晕才分得开；纯黑菜单栏上这圈晕看不见。模糊半径按位图像素算，3px = 1.5pt
            ctx.setShadow(offset: .zero, blur: 3, color: CGColor(gray: 0, alpha: 0.75))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.scaleBy(x: scale, y: scale)
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: 34, height: 18))
        // 以下 y 朝下，和 Stride 预览页的坐标一致
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        drawEgg(in: ctx, memory: min(max(memory, 0), 1), palette: palette(dark: dark))
        ctx.endTransparencyLayer()
        return ctx.makeImage().map { NSImage(cgImage: $0, size: size) }
    }

    private struct Palette {
        let calm, warm, hot, outline, nest: CGColor
    }

    /// 平时跟菜单栏深浅走白 / 黑。橙和草窝在深色模式下提亮成浅色：饱和橙、土黄在壁纸染色的中灰蓝菜单栏上和底色一样暗。
    private static func palette(dark: Bool) -> Palette {
        dark
            ? Palette(calm: CGColor(gray: 1, alpha: 1), warm: srgb(0xffcf70), hot: srgb(0xff453a),
                      outline: CGColor(gray: 1, alpha: 0.95), nest: srgb(0xf0c890))
            : Palette(calm: CGColor(gray: 0, alpha: 1), warm: srgb(0xb35200), hot: srgb(0xd70015),
                      outline: CGColor(gray: 0, alpha: 0.95), nest: srgb(0x7a4a1f))
    }

    private static func srgb(_ hex: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    private static func drawEgg(in ctx: CGContext, memory: Double, palette p: Palette) {
        let cx: CGFloat = 39.8, waist: CGFloat = 10.3, rx: CGFloat = 3.8, up: CGFloat = 6.1, down: CGFloat = 4.4
        let top = waist - up, bottom = waist + down
        let level = bottom - (bottom - top) * CGFloat(memory)
        let tone = StrideRule.eggTone(memory: memory)
        let fill = tone == .hot ? p.hot : tone == .warm ? p.warm : p.calm

        // 高的上半椭圆接矮的下半椭圆：上尖下圆才像蛋，一个整椭圆看着像药丸
        let egg = CGMutablePath()
        egg.addArc(center: .zero, radius: 1, startAngle: .pi, endAngle: 2 * .pi, clockwise: false,
                   transform: CGAffineTransform(translationX: cx, y: waist).scaledBy(x: rx, y: up))
        egg.addArc(center: .zero, radius: 1, startAngle: 0, endAngle: .pi, clockwise: false,
                   transform: CGAffineTransform(translationX: cx, y: waist).scaledBy(x: rx, y: down))
        egg.closeSubpath()

        // 斑点再小（半径 0.55–0.75pt）18pt 下就是几个灰像素
        let spots: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [(cx - 1.5, waist - 2.9, 1.05), (cx + 1.4, waist - 0.5, 0.9), (cx - 0.8, waist + 2.0, 0.8)]
        func addSpots() {
            for spot in spots {
                ctx.addEllipse(in: CGRect(x: spot.x - spot.r, y: spot.y - spot.r, width: 2 * spot.r, height: 2 * spot.r))
            }
        }

        ctx.saveGState()
        ctx.addPath(egg)
        ctx.clip()
        // 斑点：空着的那截画成描边色，填上的那截挖成透明，两截都看得见
        ctx.setFillColor(p.outline)
        addSpots()
        ctx.fillPath()
        let filled = CGRect(x: cx - rx - 1, y: level, width: 2 * rx + 2, height: bottom - level + 1)
        ctx.setFillColor(fill)
        ctx.fill(filled)
        ctx.clip(to: filled)
        ctx.setBlendMode(.clear)
        addSpots()
        ctx.fillPath()
        ctx.restoreGState()

        ctx.setLineWidth(1.0)
        ctx.setStrokeColor(p.outline)
        ctx.addPath(egg)
        ctx.strokePath()

        if tone == .hot {
            // 内存吃紧：蛋壳裂开
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(0.9)
            ctx.setLineJoin(.round)
            ctx.addLines(between: [CGPoint(x: cx - rx, y: waist - 1.2), CGPoint(x: cx - 1.5, y: waist - 2.3), CGPoint(x: cx - 0.2, y: waist - 0.9),
                                   CGPoint(x: cx + 1.2, y: waist - 2.5), CGPoint(x: cx + rx, y: waist - 1.4)])
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 草窝：实心碗形托住蛋底，两边各翘一根草。原来的细线草窝（1.3pt 弧 + 0.7pt 草）在菜单栏里几乎看不见
        ctx.setFillColor(p.nest)
        ctx.move(to: CGPoint(x: cx - 5.2, y: 13.2))
        ctx.addQuadCurve(to: CGPoint(x: cx + 5.2, y: 13.2), control: CGPoint(x: cx, y: 19.4))
        ctx.addLine(to: CGPoint(x: cx + 3.9, y: 13.9))
        ctx.addQuadCurve(to: CGPoint(x: cx - 3.9, y: 13.9), control: CGPoint(x: cx, y: 15.6))
        ctx.closePath()
        ctx.fillPath()
        ctx.setStrokeColor(p.nest)
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: cx - 4.6, y: 13.5))
        ctx.addLine(to: CGPoint(x: cx - 5.6, y: 12.3))
        ctx.move(to: CGPoint(x: cx + 4.6, y: 13.5))
        ctx.addLine(to: CGPoint(x: cx + 5.6, y: 12.4))
        ctx.strokePath()
    }
}
