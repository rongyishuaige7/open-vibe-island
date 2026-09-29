import SwiftUI
import OpenIslandCore

/// The mascots right slot: one pixel critter per agent tool, feet on a shared
/// baseline. Ticks at 8 fps only while a mascot is running or waiting.
struct PixelMascotRow: View {
    let slots: [PixelMascotSlot]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let cellWidth: CGFloat = 1
    static let cellHeight: CGFloat = 2
    static let spacing: CGFloat = 2

    static func intrinsicWidth(of slots: [PixelMascotSlot]) -> CGFloat {
        guard !slots.isEmpty else { return 0 }
        let columns = slots.reduce(0) { $0 + PixelSprite.sprite(for: $1.tool).columns }
        return CGFloat(columns) * cellWidth + CGFloat(slots.count - 1) * spacing
    }

    /// Tallest sprite plus headroom for the walking bob.
    static func height(of slots: [PixelMascotSlot]) -> CGFloat {
        let rows = slots.map { PixelSprite.sprite(for: $0.tool).rowCount }.max() ?? 0
        return CGFloat(rows) * cellHeight + PixelMascotMotion.bobHeight
    }

    private var animates: Bool {
        !reduceMotion && slots.contains { $0.state != .idle }
    }

    var body: some View {
        Group {
            if animates {
                TimelineView(.periodic(from: .now, by: PixelMascotMotion.tick)) { context in
                    canvas(time: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvas(time: nil)
            }
        }
        .frame(width: Self.intrinsicWidth(of: slots), height: Self.height(of: slots))
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    private func canvas(time: TimeInterval?) -> some View {
        Canvas { context, size in
            var x: CGFloat = 0
            for slot in slots {
                let sprite = PixelSprite.sprite(for: slot.tool)
                Self.draw(sprite, slot: slot, originX: x, in: &context, height: size.height, time: time)
                x += CGFloat(sprite.columns) * Self.cellWidth + Self.spacing
            }
        }
    }

    private static func draw(
        _ sprite: PixelSprite,
        slot: PixelMascotSlot,
        originX: CGFloat,
        in context: inout GraphicsContext,
        height: CGFloat,
        time: TimeInterval?
    ) {
        let color = Color(hex: slot.tool.brandColorHex) ?? .gray
        let frame = PixelMascotMotion.walkFrame(state: slot.state, time: time)
        let rows = sprite.rows(
            frame: frame,
            cursorVisible: PixelMascotMotion.cursorVisible(state: slot.state, time: time)
        )
        let alpha = PixelMascotMotion.alpha(state: slot.state, time: time)
        let bob = frame == 1 ? PixelMascotMotion.bobHeight : 0
        let top = height - CGFloat(sprite.rowCount) * cellHeight - bob

        for (rowIndex, line) in rows.enumerated() {
            let isFeet = rowIndex == rows.count - 1
            for (column, character) in line.enumerated() where character == "#" {
                var cellAlpha = alpha
                // The body shimmers while running; the feet stay solid.
                if slot.state == .running, !isFeet, let time {
                    cellAlpha *= 0.8 + 0.2 * PixelMascotMotion.shimmer(column: column, row: rowIndex, time: time)
                }
                let rect = CGRect(
                    x: originX + CGFloat(column) * cellWidth,
                    y: top + CGFloat(rowIndex) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                context.fill(Path(rect), with: .color(color.opacity(cellAlpha)))
            }
        }
    }

    private var accessibilitySummary: String {
        let lang = LanguageManager.shared
        return slots.map { slot in
            let state = switch slot.state {
            case .running: lang.t("island.section.inProgress")
            case .waiting: lang.t("island.mascot.waiting")
            case .idle: lang.t("island.section.idle")
            }
            return "\(slot.tool.displayName) \(state)"
        }
        .joined(separator: ", ")
    }
}

/// Completed-row marker for the `.pixel` session-state style.
struct PixelCheckmark: View {
    let tint: Color
    var cell: CGFloat = 1.5

    var body: some View {
        let rows = PixelCheckmarkBitmap.rows
        let columns = rows.first?.count ?? 0
        Canvas { context, _ in
            for (rowIndex, line) in rows.enumerated() {
                for (column, character) in line.enumerated() where character == "#" {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(rowIndex) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(tint))
                }
            }
        }
        .frame(width: CGFloat(columns) * cell, height: CGFloat(rows.count) * cell)
        .accessibilityHidden(true)
    }
}
