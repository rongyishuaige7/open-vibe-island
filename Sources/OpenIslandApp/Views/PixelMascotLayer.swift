import AppKit
import SwiftUI
import OpenIslandCore

struct PixelMascotLayerRepresentable: NSViewRepresentable {
    let slots: [PixelMascotSlot]
    let reduceMotion: Bool

    func makeNSView(context: Context) -> PixelMascotLayerView {
        let view = PixelMascotLayerView()
        view.update(slots: slots, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ nsView: PixelMascotLayerView, context: Context) {
        nsView.update(slots: slots, reduceMotion: reduceMotion)
    }
}

/// One layer per mascot. Running mascots cycle pre-rendered frames with a
/// discrete `contents` keyframe animation and waiting ones animate opacity,
/// so the render server plays them without waking the app.
final class PixelMascotLayerView: NSView {
    private struct Configuration: Equatable {
        var slots: [PixelMascotSlot]
        var reduceMotion: Bool
        var size: CGSize
        var scale: CGFloat
    }

    private var slots: [PixelMascotSlot] = []
    private var reduceMotion = false
    private var configured: Configuration?
    private var spriteLayers: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(slots: [PixelMascotSlot], reduceMotion: Bool) {
        guard slots != self.slots || reduceMotion != self.reduceMotion else { return }
        self.slots = slots
        self.reduceMotion = reduceMotion
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let configuration = Configuration(slots: slots, reduceMotion: reduceMotion, size: bounds.size, scale: scale)
        // Reapplying restarts the animations, so only do it when something changed.
        guard configuration != configured else { return }
        configured = configuration
        configureLayers(scale: scale)
    }

    private func configureLayers(scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayers.forEach { $0.removeFromSuperlayer() }
        spriteLayers = []
        var x: CGFloat = 0
        for slot in slots {
            let sprite = PixelSprite.sprite(for: slot.tool)
            let frames = PixelMascotRenderer.frames(for: slot, scale: scale, animated: !reduceMotion)
            let spriteLayer = CALayer()
            // Feet on the shared baseline at the bottom of the row.
            spriteLayer.frame = CGRect(
                x: x,
                y: 0,
                width: PixelMascotRenderer.width(of: sprite),
                height: PixelMascotRenderer.height(of: sprite)
            )
            spriteLayer.contentsScale = scale
            spriteLayer.magnificationFilter = .nearest
            spriteLayer.contents = frames.first
            spriteLayer.opacity = PixelMascotMotion.opacity(for: slot.state)
            if !reduceMotion {
                addAnimations(to: spriteLayer, state: slot.state, frames: frames)
            }
            layer?.addSublayer(spriteLayer)
            spriteLayers.append(spriteLayer)
            x += PixelMascotRenderer.width(of: sprite) + PixelMascotRow.spacing
        }
        CATransaction.commit()
    }

    private func addAnimations(to spriteLayer: CALayer, state: AgentGridCellState, frames: [CGImage]) {
        switch state {
        case .running where frames.count > 1:
            let walk = CAKeyframeAnimation(keyPath: "contents")
            walk.values = frames
            walk.calculationMode = .discrete
            walk.keyTimes = (0...frames.count).map { NSNumber(value: Double($0) / Double(frames.count)) }
            walk.duration = PixelMascotMotion.cycleDuration
            walk.repeatCount = .infinity
            spriteLayer.add(walk, forKey: "walk")
        case .waiting:
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = PixelMascotMotion.breathMinOpacity
            breathe.toValue = Float(1)
            breathe.duration = PixelMascotMotion.breathDuration
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            spriteLayer.add(breathe, forKey: "breathe")
        case .running, .idle:
            break
        }
    }
}

/// Renders mascot frames into bitmaps for `PixelMascotLayerView`.
@MainActor
enum PixelMascotRenderer {
    static func width(of sprite: PixelSprite) -> CGFloat {
        CGFloat(sprite.columns) * PixelMascotRow.cellWidth
    }

    /// Sprite height plus headroom for the walking bob.
    static func height(of sprite: PixelSprite) -> CGFloat {
        CGFloat(sprite.rowCount) * PixelMascotRow.cellHeight + PixelMascotMotion.bobHeight
    }

    /// The walk-and-blink keyframes while running, a single still otherwise.
    static func frames(for slot: PixelMascotSlot, scale: CGFloat, animated: Bool) -> [CGImage] {
        let sprite = PixelSprite.sprite(for: slot.tool)
        let color = NSColor(Color(hex: slot.tool.brandColorHex) ?? .gray).cgColor
        guard animated, slot.state == .running else {
            return [render(sprite, frame: 0, cursorVisible: true, shimmerTime: nil, color: color, scale: scale)]
                .compactMap { $0 }
        }
        return PixelMascotMotion.keyframeTimes.compactMap { time in
            render(
                sprite,
                frame: PixelMascotMotion.walkFrame(state: .running, time: time),
                cursorVisible: PixelMascotMotion.cursorVisible(state: .running, time: time),
                shimmerTime: time,
                color: color,
                scale: scale
            )
        }
    }

    private static func render(
        _ sprite: PixelSprite,
        frame: Int,
        cursorVisible: Bool,
        shimmerTime: TimeInterval?,
        color: CGColor,
        scale: CGFloat
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int((width(of: sprite) * scale).rounded()),
            height: Int((height(of: sprite) * scale).rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(false)

        let rows = sprite.rows(frame: frame, cursorVisible: cursorVisible)
        let lift = frame == 1 ? PixelMascotMotion.bobHeight : 0
        for (rowIndex, line) in rows.enumerated() {
            let isFeet = rowIndex == rows.count - 1
            // Bitmap y runs bottom-up; row 0 is the sprite's top.
            let y = lift + CGFloat(rows.count - 1 - rowIndex) * PixelMascotRow.cellHeight
            for (column, character) in line.enumerated() where character == "#" {
                var alpha: CGFloat = 1
                // The running body shimmers; the feet stay solid.
                if let shimmerTime, !isFeet {
                    alpha = 0.8 + 0.2 * PixelMascotMotion.shimmer(column: column, row: rowIndex, time: shimmerTime)
                }
                context.setFillColor(color.copy(alpha: alpha) ?? color)
                context.fill(CGRect(
                    x: CGFloat(column) * PixelMascotRow.cellWidth,
                    y: y,
                    width: PixelMascotRow.cellWidth,
                    height: PixelMascotRow.cellHeight
                ))
            }
        }
        return context.makeImage()
    }
}
