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

/// One layer per mascot plus a still layer per mark. Running mascots cycle
/// pre-rendered frames with a discrete `contents` keyframe animation and
/// waiting ones animate opacity, so the render server plays them without
/// waking the app.
final class PixelMascotLayerView: NSView {
    /// Everything that shapes the sprite layers. Marks stay out of it so a
    /// mark coming or going never restarts a walk.
    private struct SpriteConfiguration: Equatable {
        var tools: [AgentTool]
        var states: [AgentGridCellState]
        var reduceMotion: Bool
        var size: CGSize
        var scale: CGFloat
    }

    private var slots: [PixelMascotSlot] = []
    private var reduceMotion = false
    private var configuredSprites: SpriteConfiguration?
    private var configuredMarks: [PixelMascotMark?]?
    private var spriteLayers: [CALayer] = []
    private var markLayers: [CALayer] = []

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

    /// Purely decorative, and it reaches up into the marks' headroom: let
    /// clicks fall through to the island underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
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
        let sprites = SpriteConfiguration(
            tools: slots.map(\.tool),
            states: slots.map(\.state),
            reduceMotion: reduceMotion,
            size: bounds.size,
            scale: scale
        )
        // Reapplying restarts the animations, so only do it when something changed.
        if sprites != configuredSprites {
            configuredSprites = sprites
            configureSpriteLayers(scale: scale)
            // Fresh sprite layers still need their marks and resting opacity.
            configuredMarks = nil
        }
        let marks = slots.map(\.mark)
        guard marks != configuredMarks else { return }
        configuredMarks = marks
        configureMarkLayers(scale: scale)
    }

    private func configureSpriteLayers(scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayers.forEach { $0.removeFromSuperlayer() }
        spriteLayers = []
        let spriteFrames = PixelMascotRenderer.spriteFrames(for: slots.map(\.tool))
        for (slot, spriteFrame) in zip(slots, spriteFrames) {
            let images = PixelMascotRenderer.frames(for: slot, scale: scale, animated: !reduceMotion)
            let spriteLayer = CALayer()
            spriteLayer.frame = spriteFrame
            spriteLayer.contentsScale = scale
            spriteLayer.magnificationFilter = .nearest
            spriteLayer.contents = images.first
            if !reduceMotion {
                addAnimations(to: spriteLayer, state: slot.state, frames: images)
            }
            layer?.addSublayer(spriteLayer)
            spriteLayers.append(spriteLayer)
        }
        CATransaction.commit()
    }

    /// Marks are stills, so swapping one leaves the sprite animations alone.
    private func configureMarkLayers(scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayers.forEach { $0.removeFromSuperlayer() }
        markLayers = []
        for (slot, spriteLayer) in zip(slots, spriteLayers) {
            spriteLayer.opacity = PixelMascotMotion.opacity(for: slot.state, mark: slot.mark)
            guard let mark = slot.mark,
                  let image = PixelMascotRenderer.markImage(for: mark, scale: scale) else { continue }
            let markLayer = CALayer()
            markLayer.frame = PixelMascotRenderer.markFrame(for: mark, above: spriteLayer.frame, scale: scale)
            markLayer.contentsScale = scale
            markLayer.magnificationFilter = .nearest
            markLayer.contents = image
            layer?.addSublayer(markLayer)
            markLayers.append(markLayer)
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

    /// Sprites left to right, feet on the shared baseline at the bottom.
    static func spriteFrames(for tools: [AgentTool]) -> [CGRect] {
        var x: CGFloat = 0
        return tools.map { tool in
            let sprite = PixelSprite.sprite(for: tool)
            let frame = CGRect(x: x, y: 0, width: width(of: sprite), height: height(of: sprite))
            x += frame.width + PixelMascotRow.spacing
            return frame
        }
    }

    static func markSize(of mark: PixelMascotMark) -> CGSize {
        CGSize(
            width: CGFloat(mark.rows.first?.count ?? 0) * PixelMascotMark.cell,
            height: CGFloat(mark.rows.count) * PixelMascotMark.cell
        )
    }

    /// Centered over the sprite and clear of its bob, snapped to device
    /// pixels so the cells stay crisp.
    static func markFrame(for mark: PixelMascotMark, above spriteFrame: CGRect, scale: CGFloat) -> CGRect {
        let size = markSize(of: mark)
        let x = ((spriteFrame.midX - size.width / 2) * scale).rounded(.down) / scale
        let y = ((spriteFrame.maxY + PixelMascotMark.gap) * scale).rounded(.down) / scale
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func markImage(for mark: PixelMascotMark, scale: CGFloat) -> CGImage? {
        let size = markSize(of: mark)
        guard let context = CGContext(
            data: nil,
            width: Int((size.width * scale).rounded()),
            height: Int((size.height * scale).rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(false)
        context.setFillColor(NSColor(markTint(for: mark)).cgColor)
        let rows = mark.rows
        for (rowIndex, line) in rows.enumerated() {
            // Bitmap y runs bottom-up; row 0 is the mark's top.
            let y = CGFloat(rows.count - 1 - rowIndex) * PixelMascotMark.cell
            for (column, character) in line.enumerated() where character == "#" {
                context.fill(CGRect(
                    x: CGFloat(column) * PixelMascotMark.cell,
                    y: y,
                    width: PixelMascotMark.cell,
                    height: PixelMascotMark.cell
                ))
            }
        }
        return context.makeImage()
    }

    /// The same tints the session list uses for these states.
    static func markTint(for mark: PixelMascotMark) -> Color {
        switch mark {
        case .approval: IslandDesignPalette.Status.waitingForApproval
        case .answer: IslandDesignPalette.Status.waitingForAnswer
        case .unseenDone: IslandDesignPalette.Status.completed
        }
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
