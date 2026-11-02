import Testing
@testable import OpenIslandCore

struct TokenCountFormatterTests {
    @Test
    func keepsSmallCountsExact() {
        #expect(TokenCountFormatter.compact(0, languageCode: "en") == "0")
        #expect(TokenCountFormatter.compact(950, languageCode: "en") == "950")
        #expect(TokenCountFormatter.compact(9_999, languageCode: "zh-Hans") == "9999")
        #expect(TokenCountFormatter.compact(-5, languageCode: "en") == "0")
    }

    @Test
    func usesMetricSuffixesOutsideChinese() {
        #expect(TokenCountFormatter.compact(1_000, languageCode: "en") == "1K")
        #expect(TokenCountFormatter.compact(12_340, languageCode: "en") == "12.3K")
        #expect(TokenCountFormatter.compact(52_340_000, languageCode: "en") == "52.3M")
        #expect(TokenCountFormatter.compact(123_400_000, languageCode: "en") == "123M")
        #expect(TokenCountFormatter.compact(1_500_000_000, languageCode: "en") == "1.5B")
    }

    @Test
    func usesWanAndYiInChinese() {
        #expect(TokenCountFormatter.compact(12_340, languageCode: "zh-Hans") == "1.23万")
        #expect(TokenCountFormatter.compact(20_000, languageCode: "zh-Hans") == "2万")
        #expect(TokenCountFormatter.compact(52_340_000, languageCode: "zh-Hans") == "5234万")
        #expect(TokenCountFormatter.compact(123_400_000, languageCode: "zh-Hans") == "1.23亿")
        #expect(TokenCountFormatter.compact(52_340_000, languageCode: "zh-Hant") == "5234萬")
        #expect(TokenCountFormatter.compact(123_400_000, languageCode: "zh-Hant") == "1.23億")
    }

    @Test
    func roundingCarriesIntoTheNextUnit() {
        #expect(TokenCountFormatter.compact(999_600, languageCode: "en") == "1M")
        #expect(TokenCountFormatter.compact(99_996_000, languageCode: "zh-Hans") == "1亿")
    }
}
