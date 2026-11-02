import Foundation
import Testing
@testable import OpenIslandCore

struct AgyProAccountsTests {
    @Test
    func parsesCommonSeparators() {
        let parsed = AgyProAccounts.parse("wisnumandala302@gmail.com, Bar@Example.com\nbaz;  qux")
        #expect(parsed == ["wisnumandala302", "Bar", "baz", "qux"])
    }

    @Test
    func parsesFullWidthSeparators() {
        #expect(AgyProAccounts.parse("甲@example.com，乙；丙") == ["甲", "乙", "丙"])
    }

    @Test
    func deduplicatesCaseInsensitivelyKeepingTheFirstSpelling() {
        #expect(AgyProAccounts.parse("Foo, foo@x.com, FOO") == ["Foo"])
    }

    @Test
    func blankInputFallsBackToTheBuiltInAccount() {
        #expect(AgyProAccounts.effective("  \n ") == KeeperUsageReader.defaultAgyProAccounts)
    }

    @Test
    func configuredAccountsReplaceTheBuiltInOne() {
        #expect(AgyProAccounts.effective("a@x.com b") == ["a", "b"])
    }
}
