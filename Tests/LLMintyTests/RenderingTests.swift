import XCTest
@testable import llminty

final class RenderingTests: XCTestCase {

    // MARK: - Shared regex (multi-use)

    /// Regex for a rich sentinel that replaces an implementation body.
    private static let richSentinelPattern =
    #"\{\s*/\*\s*elided-implemented;\s*lines=\d+;\s*h=[0-9a-f]{8,12}\s*\*/\s*\}"#

    private func containsMatch(in text: String, pattern: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    // MARK: - Baseline

    /// Maps score to policy.
    func testPolicyForThresholds() {
        let renderer = Renderer()
        XCTAssertEqual(renderer.policyFor(score: 0.80), .keepAllBodiesLightlyCondensed)
        XCTAssertEqual(renderer.policyFor(score: 0.60), .keepPublicBodiesElideOthers)
        XCTAssertEqual(renderer.policyFor(score: 0.30), .keepOneBodyPerTypeElideRest)
        XCTAssertEqual(renderer.policyFor(score: 0.10), .signaturesOnly)
    }

    /// Emits rich sentinel under `.signaturesOnly`.
    func testElidedFuncUsesRichSentinel() throws {
        let source = """
        struct T {
            func recompute(_ n: Int) -> Int {
                var sum = 0
                for i in 0..<n { sum += i }
                return sum
            }
        }
        """
        let result = try Renderer().renderSwift(text: source, policy: .signaturesOnly)
        XCTAssertTrue(result.contains("func recompute"))
        XCTAssertTrue(containsMatch(in: result, pattern: Self.richSentinelPattern))
    }

    /// Sentinel hash is stable for identical input.
    func testSentinelHashIsStableForSameInput() throws {
        let source = """
        func foo() {
            let items = (0..<10).map { $0 * 2 }
            print(items.reduce(0, +))
        }
        """
        let renderer = Renderer()
        let first = try renderer.renderSwift(text: source, policy: .signaturesOnly)
        let second = try renderer.renderSwift(text: source, policy: .signaturesOnly)

        let capture = #"h=([0-9a-f]{8,12})"#
        let regex = try! NSRegularExpression(pattern: capture)

        func grabHash(_ s: String) -> String? {
            let range = NSRange(s.startIndex..., in: s)
            return regex.firstMatch(in: s, range: range).map { (s as NSString).substring(with: $0.range(at: 1)) }
        }

        guard let h1 = grabHash(first), let h2 = grabHash(second) else {
            XCTFail("expected short hash in both renders"); return
        }
        XCTAssertEqual(h1, h2)
    }

    // MARK: - Core

    /// Policy cutoffs are inclusive.
    func testPolicyBoundariesAreInclusiveAtCutoffs() {
        let renderer = Renderer()
        XCTAssertEqual(renderer.policyFor(score: 0.8000), .keepAllBodiesLightlyCondensed)
        XCTAssertEqual(renderer.policyFor(score: 0.7999), .keepPublicBodiesElideOthers)
        XCTAssertEqual(renderer.policyFor(score: 0.6000), .keepPublicBodiesElideOthers)
        XCTAssertEqual(renderer.policyFor(score: 0.5999), .keepOneBodyPerTypeElideRest)
        XCTAssertEqual(renderer.policyFor(score: 0.3000), .keepOneBodyPerTypeElideRest)
        XCTAssertEqual(renderer.policyFor(score: 0.2999), .signaturesOnly)
    }

    /// Rendering routes to policy by score.
    func testRenderRoutingUsesScoreToSelectPolicy() throws {
        let analyzed = AnalyzedFile(
            file: RepoFile(
                relativePath: "R.swift",
                absoluteURL: URL(fileURLWithPath: "/dev/null"),
                isDirectory: false,
                kind: .swift,
                size: 0
            ),
            text:
            """
            public struct R {
                public func keepMe() { print("PUBLIC_BODY") }
                func dropMe() { print("INTERNAL_BODY") }
            }
            """,
            declaredTypes: [],
            publicAPIScoreRaw: 0,
            referencedTypes: [:],
            complexity: 0,
            isEntrypoint: false,
            outgoingFileDeps: [],
            inboundRefCount: 0
        )
        let renderer = Renderer()

        let keepAll = try renderer.render(file: ScoredFile(analyzed: analyzed, score: 0.85, fanIn: 0, pageRank: 0), score: 0.85).content
        XCTAssertTrue(keepAll.contains("PUBLIC_BODY"))
        XCTAssertTrue(keepAll.contains("INTERNAL_BODY"))

        let keepPublic = try renderer.render(file: ScoredFile(analyzed: analyzed, score: 0.65, fanIn: 0, pageRank: 0), score: 0.65).content
        XCTAssertTrue(keepPublic.contains("PUBLIC_BODY"))
        XCTAssertFalse(keepPublic.contains("INTERNAL_BODY"))
        XCTAssertFalse(containsMatch(in: keepPublic, pattern: Self.richSentinelPattern))
        XCTAssertTrue(keepPublic.contains("{ ... }"))

        let signaturesOnly = try renderer.render(file: ScoredFile(analyzed: analyzed, score: 0.25, fanIn: 0, pageRank: 0), score: 0.25).content
        XCTAssertFalse(signaturesOnly.contains("PUBLIC_BODY"))
        XCTAssertFalse(signaturesOnly.contains("INTERNAL_BODY"))
        XCTAssertTrue(containsMatch(in: signaturesOnly, pattern: Self.richSentinelPattern))
    }

    /// Keep-all preserves bodies and `{}`.
    func testKeepAllBodiesDoesNotElideOrCanonicalize() throws {
        let source = """
        struct K {
            func empty() {}
            func nonEmpty() { print("X") }
        }
        """
        let result = try Renderer().renderSwift(text: source, policy: .keepAllBodiesLightlyCondensed)
        XCTAssertTrue(result.contains("print(\"X\")"))
        XCTAssertTrue(result.contains("{}"))
        XCTAssertFalse(containsMatch(in: result, pattern: Self.richSentinelPattern))
    }

    /// Under keep-public, `open` kept; `internal`/`package` elided.
    func testOpenIsKept_InternalAndPackageAreElided() throws {
        let source = """
        open class OC { open func of() { print("O") } }
        struct IC { func i() { print("I") } }
        package func pkg() { print("P") }
        """
        let result = try Renderer().renderSwift(text: source, policy: .keepPublicBodiesElideOthers)

        XCTAssertTrue(result.contains("open func of()"))
        XCTAssertTrue(result.contains("print(\"O\")"))

        XCTAssertTrue(result.contains("func i()"))
        XCTAssertFalse(result.contains("print(\"I\")"))

        XCTAssertTrue(result.contains("package func pkg()"))
        XCTAssertFalse(result.contains("print(\"P\")"))

        XCTAssertFalse(containsMatch(in: result, pattern: Self.richSentinelPattern))
        XCTAssertTrue(result.contains("{ ... }"))
    }

    /// Keep-one keeps only the first executable per container.
    func testOneBodyPerContainerOnlyFirstExecutableIsKept() throws {
        let source = """
        struct C {
            init() { print("FIRST") }
            func second() { print("SECOND") }
            func third() { print("THIRD") }
        }
        """
        let result = try Renderer().renderSwift(text: source, policy: .keepOneBodyPerTypeElideRest)
        XCTAssertTrue(result.contains("print(\"FIRST\")"))
        XCTAssertFalse(result.contains("print(\"SECOND\")"))
        XCTAssertFalse(result.contains("print(\"THIRD\")"))
        XCTAssertTrue(result.contains("{ ... }"))
    }

    /// Computed properties don't take the "one body" slot.
    func testComputedPropertiesDoNotCountTowardOne() throws {
        let source = """
        struct D {
            var v: Int { get { 1 } set { _ = newValue } }
            func kept() { print("KEPT") }
            func elided() { print("ELIDED") }
        }
        """
        let result = try Renderer().renderSwift(text: source, policy: .keepOneBodyPerTypeElideRest)
        XCTAssertTrue(result.contains("print(\"KEPT\")"))
        XCTAssertFalse(result.contains("print(\"ELIDED\")"))
        XCTAssertTrue(result.contains("{ ... }"))
    }

    /// Extensions are separate containers for keep-one.
    func testExtensionsAreSeparateContainers() throws {
        let source = """
        struct E {
            func e1() { print("E1") }
            func e2() { print("E2") }
        }
        extension E {
            func x1() { print("X1") }
            func x2() { print("X2") }
        }
        """
        let result = try Renderer().renderSwift(text: source, policy: .keepOneBodyPerTypeElideRest)
        XCTAssertTrue(result.contains("print(\"E1\")"))
        XCTAssertFalse(result.contains("print(\"E2\")"))
        XCTAssertTrue(result.contains("print(\"X1\")"))
        XCTAssertFalse(result.contains("print(\"X2\")"))
    }

    /// Accessors use sentinel only under `.signaturesOnly`.
    func testAccessorsSentinelOnlyUnderSignaturesOnly() throws {
        let source = """
        public struct A {
            public var value: Int {
                get { 1 }
                set { _ = newValue + 1 }
            }
        }
        """
        let signaturesOnly = try Renderer().renderSwift(text: source, policy: .signaturesOnly)
        XCTAssertTrue(containsMatch(in: signaturesOnly, pattern: Self.richSentinelPattern))

        let keepPublic = try Renderer().renderSwift(text: source, policy: .keepPublicBodiesElideOthers)
        XCTAssertFalse(containsMatch(in: keepPublic, pattern: Self.richSentinelPattern))
    }

    /// Empty `{}` canonicalized to `{ ... }` unless keep-all.
    func testCanonicalizeEmptyBlocksOnlyWhenPolicyIsNotKeepAll() throws {
        let source = """
        struct Z {
            func empty() {}
            func nonEmpty() { print("Z") }
        }
        """
        let keepAll = try Renderer().renderSwift(text: source, policy: .keepAllBodiesLightlyCondensed)
        XCTAssertTrue(keepAll.contains("{}"))

        let keepPublic = try Renderer().renderSwift(text: source, policy: .keepPublicBodiesElideOthers)
        XCTAssertFalse(keepPublic.contains("{}"))
        XCTAssertTrue(keepPublic.contains("{ ... }"))
    }

    /// Compacts 3+ blank lines to 1 for text and unknown files.
    func testTextAndUnknownWhitespaceIsCompacted() throws {
        let textFile = AnalyzedFile(
            file: RepoFile(
                relativePath: "Notes.txt",
                absoluteURL: URL(fileURLWithPath: "/dev/null"),
                isDirectory: false,
                kind: .text,
                size: 0
            ),
            text: "a\n\n\n b\n",
            declaredTypes: [],
            publicAPIScoreRaw: 0,
            referencedTypes: [:],
            complexity: 0,
            isEntrypoint: false,
            outgoingFileDeps: [],
            inboundRefCount: 0
        )
        let unknownFile = AnalyzedFile(
            file: RepoFile(
                relativePath: "blob.unknown",
                absoluteURL: URL(fileURLWithPath: "/dev/null"),
                isDirectory: false,
                kind: .unknown,
                size: 0
            ),
            text: "x\n\n\n y\n",
            declaredTypes: [],
            publicAPIScoreRaw: 0,
            referencedTypes: [:],
            complexity: 0,
            isEntrypoint: false,
            outgoingFileDeps: [],
            inboundRefCount: 0
        )

        let textResult = try Renderer().render(file: ScoredFile(analyzed: textFile, score: 0.1, fanIn: 0, pageRank: 0.0), score: 0.1).content
        XCTAssertFalse(textResult.contains("\n\n\n"))
        XCTAssertTrue(textResult.contains("\n\n"))

        let unknownResult = try Renderer().render(file: ScoredFile(analyzed: unknownFile, score: 0.2, fanIn: 0, pageRank: 0.0), score: 0.2).content
        XCTAssertFalse(unknownResult.contains("\n\n\n"))
        XCTAssertTrue(unknownResult.contains("\n\n"))
    }

    /// Binary files show a size placeholder.
    func testBinaryFilesEmitSizePlaceholder() throws {
        let analyzed = AnalyzedFile(
            file: RepoFile(
                relativePath: "blob.dat",
                absoluteURL: URL(fileURLWithPath: "/dev/null"),
                isDirectory: false,
                kind: .binary,
                size: 1234
            ),
            text: "",
            declaredTypes: [],
            publicAPIScoreRaw: 0,
            referencedTypes: [:],
            complexity: 0,
            isEntrypoint: false,
            outgoingFileDeps: [],
            inboundRefCount: 0
        )
        let scored = ScoredFile(analyzed: analyzed, score: 0.5, fanIn: 0, pageRank: 0)
        let content = try Renderer().render(file: scored, score: scored.score).content
        XCTAssertTrue(content.contains("binary omitted; size=1234 bytes"))
    }
}
