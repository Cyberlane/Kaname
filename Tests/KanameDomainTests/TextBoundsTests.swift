import Testing
@testable import KanameDomain

struct TextBoundsTests {
    @Test
    func utf8EdgesPreserveWholeScalarsWithinTheExactByteLimit() {
        #expect(KanameTextBounds.utf8Prefix("plain", maximumBytes: 5) == "plain")
        #expect(KanameTextBounds.utf8Prefix("a鳥b", maximumBytes: 4) == "a鳥")
        #expect(KanameTextBounds.utf8Prefix("a鳥b", maximumBytes: 3) == "a")
        #expect(KanameTextBounds.utf8Prefix("anything", maximumBytes: 0).isEmpty)
        #expect(KanameTextBounds.utf8Suffix("plain", maximumBytes: 5) == "plain")
        #expect(KanameTextBounds.utf8Suffix("a鳥b", maximumBytes: 4) == "鳥b")
        #expect(KanameTextBounds.utf8Suffix("a鳥b", maximumBytes: 3) == "b")
        #expect(KanameTextBounds.utf8Suffix("anything", maximumBytes: 0).isEmpty)
    }
}
