import Foundation

/// Compacts token counts for the island's narrow usage chips:
/// `5234万` / `5234萬` in Chinese, `52.3M` elsewhere.
public enum TokenCountFormatter {
    /// Keeps about three significant digits. `languageCode` is a resolved app
    /// language code such as `en`, `zh-Hans` or `zh-Hant`.
    public static func compact(_ count: Int, languageCode: String) -> String {
        let value = Double(max(0, count))
        let table = units(for: languageCode)
        guard var index = table.lastIndex(where: { value >= $0.divisor }) else {
            return String(max(0, count))
        }

        var text = scaled(value / table[index].divisor)
        // Rounding can carry into the next unit: 999,600 is "1M", not "1000K".
        while index + 1 < table.count,
              (Double(text) ?? 0) * table[index].divisor >= table[index + 1].divisor {
            index += 1
            text = scaled(value / table[index].divisor)
        }
        return text + table[index].suffix
    }

    private static func units(for languageCode: String) -> [(divisor: Double, suffix: String)] {
        if languageCode.hasPrefix("zh-Hant") {
            return [(1e4, "萬"), (1e8, "億")]
        }
        if languageCode.hasPrefix("zh") {
            return [(1e4, "万"), (1e8, "亿")]
        }
        return [(1e3, "K"), (1e6, "M"), (1e9, "B")]
    }

    private static func scaled(_ value: Double) -> String {
        let fractionDigits = value < 10 ? 2 : (value < 100 ? 1 : 0)
        var text = String(format: "%.\(fractionDigits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}
