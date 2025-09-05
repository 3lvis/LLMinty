import XCTest
@testable import llminty

final class RenderingTests: XCTestCase {
    func testPolicyForThresholds() {
        let r = Renderer()
        // Original bins
        XCTAssertEqual(r.policyFor(score: 0.80), .keepAllBodiesLightlyCondensed)
        XCTAssertEqual(r.policyFor(score: 0.60), .keepPublicBodiesElideOthers)
        XCTAssertEqual(r.policyFor(score: 0.30), .keepOneBodyPerTypeElideRest)
        XCTAssertEqual(r.policyFor(score: 0.10), .signaturesOnly)
    }

    func testRenderSwiftElidesNonPublicBodiesUnderPolicy() throws {
        // Body is deliberately long (> 16 lines) so it is NOT considered "short" with new thresholds
        let longBody = (0..<20).map { _ in "print(\"x\")" }.joined(separator: "\n        ")
        let swift = """
        public struct S {
            public init() {}
            public func pub() { let x = 1; print(x) }
            func internalOne() {
                \(longBody)
            }
        }
        """

        let r = Renderer()
        let content = try r.renderSwift(text: swift, policy: .keepPublicBodiesElideOthers)

        XCTAssertTrue(content.contains("public func pub()"))
        XCTAssertTrue(content.contains("func internalOne()"))

        // Internal function body should be elided (replaced with an elision token)
        XCTAssertTrue(content.contains("internalOne()") && (content.contains("{...}") || content.contains("{ ... }") || content.contains(" ... ")))
    }

    func testRenderTextCompactsWhitespace() throws {
        let rf = AnalyzedFile(
            file: RepoFile(relativePath: "Notes.txt",
                           absoluteURL: URL(fileURLWithPath: "/dev/null"),
                           isDirectory: false, kind: .text, size: 0),
            text: "a\n\n\n b\n",
            declaredTypes: [], publicAPIScoreRaw: 0, referencedTypes: [:],
            complexity: 0, isEntrypoint: false, outgoingFileDeps: [], inboundRefCount: 0
        )
        let s = ScoredFile(analyzed: rf, score: 0.1, fanIn: 0, pageRank: 0.0)
        let out = try Renderer().render(file: s, score: s.score).content
        XCTAssertFalse(out.contains("\n\n\n"))
        XCTAssertTrue(out.contains("\n\n")) // collapsed to single blank line
    }
}
