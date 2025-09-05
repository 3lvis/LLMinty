
import XCTest
@testable import llminty

final class GraphCentralityTests: XCTestCase {
    private func analyzed(_ path: String, deps: [String]) -> AnalyzedFile {
        return AnalyzedFile(
            file: RepoFile(relativePath: path, absoluteURL: URL(fileURLWithPath: "/dev/null"), isDirectory: false, kind: .swift, size: 0),
            text: "",
            declaredTypes: [],
            publicAPIScoreRaw: 0,
            referencedTypes: [:],
            complexity: 0,
            isEntrypoint: false,
            outgoingFileDeps: deps,
            inboundRefCount: 0
        )
    }

    func testDependencyAwareOrder() {
        // A depends on B; B depends on C  => order should be C, B, A
        let a = analyzed("A.swift", deps: ["B.swift"])
        let b = analyzed("B.swift", deps: ["C.swift"])
        let c = analyzed("C.swift", deps: [])

        let scored: [ScoredFile] = [a, b, c].map { ScoredFile(analyzed: $0, score: 0.5, fanIn: 0, pageRank: 0.0) }
        let ordered = GraphCentrality.orderDependencyAware(scored).map { $0.analyzed.file.relativePath }
        XCTAssertEqual(ordered, ["C.swift", "B.swift", "A.swift"])
    }
}
