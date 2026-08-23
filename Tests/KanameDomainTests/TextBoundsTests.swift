import Testing
@testable import KanameDomain

struct TextBoundsTests {
    @Test
    func utf8PrefixPreservesWholeScalarsWithinTheExactByteLimit() {
        #expect(KanameTextBounds.utf8Prefix("plain", maximumBytes: 5) == "plain")
        #expect(KanameTextBounds.utf8Prefix("a鳥b", maximumBytes: 4) == "a鳥")
        #expect(KanameTextBounds.utf8Prefix("a鳥b", maximumBytes: 3) == "a")
        #expect(KanameTextBounds.utf8Prefix("anything", maximumBytes: 0).isEmpty)
    }
}
