import SwiftUI
import OpenIslandCore

/// The mascots right slot: one pixel critter per agent tool, feet on a shared
/// baseline. Frames are pre-rendered and played by Core Animation, like
/// `UnifiedBars`, so SwiftUI does no work while the mascots walk.
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

    var body: some View {
        PixelMascotLayerRepresentable(slots: slots, reduceMotion: reduceMotion)
            .frame(width: Self.intrinsicWidth(of: slots), height: Self.height(of: slots))
            .accessibilityElement()
            .accessibilityLabel(accessibilitySummary)
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
