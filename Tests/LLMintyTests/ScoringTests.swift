
import XCTest
@testable import llminty

final class ScoringTests: XCTestCase {
    func testScoringWeightsAndEntrypointBonus() {
        // Construct two analyzed files with different signals
        let a = AnalyzedFile(
            file: RepoFile(relativePath: "A.swift", absoluteURL: URL(fileURLWithPath: "/dev/null"), isDirectory: false, kind: .swift, size: 0),
            text: "",
            declaredTypes: [],
            publicAPIScoreRaw: 3, // larger API surface
            referencedTypes: [:],
            complexity: 5,
            isEntrypoint: true,   // entrypoint bonus
            outgoingFileDeps: ["B.swift"],
            inboundRefCount: 2
        )
        let b = AnalyzedFile(
            file: RepoFile(relativePath: "B.swift", absoluteURL: URL(fileURLWithPath: "/dev/null"), isDirectory: false, kind: .swift, size: 0),
            text: "",
            declaredTypes: [],
            publicAPIScoreRaw: 1,
            referencedTypes: [:],
            complexity: 1,
            isEntrypoint: false,
            outgoingFileDeps: [],
            inboundRefCount: 0
        )
        let scored = Scoring().score(analyzed: [a, b])
        guard let sa = scored.first(where: { $0.analyzed.file.relativePath == "A.swift" }),
              let sb = scored.first(where: { $0.analyzed.file.relativePath == "B.swift" }) else {
            return XCTFail("Missing scored files")
        }
        XCTAssertGreaterThan(sa.score, sb.score, "Entrypoint + stronger signals should outrank")
        XCTAssertTrue((0.0...1.0).contains(sa.score))
        XCTAssertTrue((0.0...1.0).contains(sb.score))
    }
}
