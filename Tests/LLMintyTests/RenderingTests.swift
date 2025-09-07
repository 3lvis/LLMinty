import XCTest
@testable import llminty

final class RenderingTests: XCTestCase {

    // MARK: - Baseline

    /// Maps score to policy.
    func testPolicyForThresholds() {
        let renderer = Renderer()
        XCTAssertEqual(renderer.policyFor(score: 0.80), .keepAllBodiesLightlyCondensed)
        XCTAssertEqual(renderer.policyFor(score: 0.60), .keepPublicBodiesElideOthers)
        XCTAssertEqual(renderer.policyFor(score: 0.30), .keepOneBodyPerTypeElideRest)
        XCTAssertEqual(renderer.policyFor(score: 0.10), .signaturesOnly)
    }

    // MARK: - Core body elision / sentinels

    /// Emits rich sentinel when bodies are elided (signaturesOnly baseline).
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
        try assertRenderContainsTemplate(
            source: source,
            policy: .signaturesOnly,
            expectedTemplate: #"func recompute(_ n: Int) -> Int { «SENTINEL» }"#
        )
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
            XCTFail("expected short hash in both renders")
            return
        }
        XCTAssertEqual(h1, h2)
    }

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

    /// Rendering routes to policy by score and uses rich sentinels for elided non-public bodies.
    func testRenderRoutingUsesScoreToSelectPolicy() throws {
        let analyzed = AnalyzedFile(
            file: RepoFile(relativePath: "R.swift", absoluteURL: URL(fileURLWithPath: "/dev/null"), isDirectory: false, kind: .swift, size: 0),
            text: """
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

        // keepAll: both bodies present
        do {
            let content = try renderer.render(file: ScoredFile(analyzed: analyzed, score: 0.85, fanIn: 0, pageRank: 0), score: 0.85).content
            assertTextMatchesTemplate(
                actual: content,
                expectedTemplate: #"public func keepMe() { «ANY»PUBLIC_BODY«ANY» }"#,
                source: analyzed.text
            )
            assertTextMatchesTemplate(
                actual: content,
                expectedTemplate: #"func dropMe() { «ANY»INTERNAL_BODY«ANY» }"#,
                source: analyzed.text
            )
        }

        // keepPublic: public body kept; internal elided
        do {
            let content = try renderer.render(file: ScoredFile(analyzed: analyzed, score: 0.65, fanIn: 0, pageRank: 0), score: 0.65).content
            assertTextMatchesTemplate(
                actual: content,
                expectedTemplate: #"public func keepMe() { «ANY»PUBLIC_BODY«ANY» }"#,
                source: analyzed.text
            )
            assertTextMatchesTemplate(
                actual: content,
                expectedTemplate: #"func dropMe() { «SENTINEL» }"#,
                source: analyzed.text
            )
        }

        // signaturesOnly: both elided
        do {
            let content = try renderer.render(file: ScoredFile(analyzed: analyzed, score: 0.25, fanIn: 0, pageRank: 0), score: 0.25).content
            assertTextMatchesTemplate(
                actual: content,
                expectedTemplate: #"public func keepMe() { «SENTINEL» }"#,
                source: analyzed.text
            )
            assertTextMatchesTemplate(
                actual: content,
                expectedTemplate: #"func dropMe() { «SENTINEL» }"#,
                source: analyzed.text
            )
        }
    }

    /// Keep-all preserves bodies and `{}`.
    func testKeepAllBodiesDoesNotElideOrCanonicalize() throws {
        let source = """
        struct K {
            func empty() {}
            func nonEmpty() { print("X") }
        }
        """
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepAllBodiesLightlyCondensed,
            expectedTemplate: #"func empty() { }"#
        )
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepAllBodiesLightlyCondensed,
            expectedTemplate: #"func nonEmpty() { «ANY»X«ANY» }"#
        )
    }

    /// Under keep-public, `open` kept; `internal`/`package` elided with rich sentinel; truly empty becomes `{ /* empty */ }`.
    func testOpenIsKept_InternalAndPackageAreElided() throws {
        let source = """
        open class OC { open func of() { print("O") } }
        struct IC { func i() { print("I") } }
        package func pkg() { print("P") }
        """
        // open kept
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepPublicBodiesElideOthers,
            expectedTemplate: #"open func of() { «ANY»O«ANY» }"#
        )
        // internal elided
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepPublicBodiesElideOthers,
            expectedTemplate: #"func i() { «SENTINEL» }"#
        )
        // package elided
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepPublicBodiesElideOthers,
            expectedTemplate: #"package func pkg() { «SENTINEL» }"#
        )
    }

    /// Keep-one keeps only the first executable per container; elided ones use rich sentinel.
    func testOneBodyPerContainerOnlyFirstExecutableIsKept() throws {
        let source = """
        struct C {
            init() { print("FIRST") }
            func second() { print("SECOND") }
            func third() { print("THIRD") }
        }
        """
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepOneBodyPerTypeElideRest,
            expectedTemplate: #"init() { «ANY»FIRST«ANY» }"#
        )
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepOneBodyPerTypeElideRest,
            expectedTemplate: #"func second() { «SENTINEL» }"#
        )
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepOneBodyPerTypeElideRest,
            expectedTemplate: #"func third() { «SENTINEL» }"#
        )
    }

    /// Computed properties: accessors that are elided use rich sentinel when non-empty; do not claim the keep-one slot.
    func testComputedPropertiesDoNotCountTowardOne() throws {
        let source = """
        struct D {
            var v: Int { get { 1 } set { _ = newValue } }
            func kept() { print("KEPT") }
            func elided() { print("ELIDED") }
        }
        """
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepOneBodyPerTypeElideRest,
            expectedTemplate: #"var v: Int { «SENTINEL» }"#
        )
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepOneBodyPerTypeElideRest,
            expectedTemplate: #"func kept() { «ANY»KEPT«ANY» }"#
        )
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepOneBodyPerTypeElideRest,
            expectedTemplate: #"func elided() { «SENTINEL» }"#
        )
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
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepOneBodyPerTypeElideRest,
            expectedTemplate: #"func e1() { «ANY»E1«ANY» }"#
        )
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepOneBodyPerTypeElideRest,
            expectedTemplate: #"func e2() { «SENTINEL» }"#
        )
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepOneBodyPerTypeElideRest,
            expectedTemplate: #"extension E { «ANY»func x1() { «ANY»X1«ANY» }«ANY» }"#
        )
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepOneBodyPerTypeElideRest,
            expectedTemplate: #"extension E { «ANY»func x2() { «SENTINEL» }«ANY» }"#
        )
    }

    /// Accessors use rich sentinel whenever elided and non-empty (not only under `.signaturesOnly`).
    func testAccessorsUseSentinelWhenElided() throws {
        let internalSource = """
        struct A {
            var value: Int {
                get { 1 }
                set { _ = newValue + 1 }
            }
        }
        """
        try assertRenderContainsTemplate(
            source: internalSource,
            policy: .signaturesOnly,
            expectedTemplate: #"var value: Int { «SENTINEL» }"#
        )
        try assertRenderContainsTemplate(
            source: internalSource,
            policy: .keepPublicBodiesElideOthers,
            expectedTemplate: #"var value: Int { «SENTINEL» }"#
        )

        let publicSource = """
        public struct A {
            public var value: Int {
                get { 1 }
                set { _ = newValue + 1 }
            }
        }
        """
        try assertRenderNotMatchTemplate(
            source: publicSource,
            policy: .keepPublicBodiesElideOthers,
            unexpectedTemplate: #"var value: Int { «SENTINEL» }"#
        )
    }

    /// NEW: Implicit getter bodies must produce rich sentinel when elided (regression test).
    func testImplicitGetterComputedPropertyUsesSentinelWhenElided() throws {
        let source = """
        extension DeclModifierListSyntax {
            var containsPublicOrOpen: Bool {
                for m in self {
                    let k = m.name.text
                    if k == "public" || k == "open" { return true }
                }
                return false
            }
        }
        """
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepPublicBodiesElideOthers,
            expectedTemplate: #"var containsPublicOrOpen: Bool { «SENTINEL» }"#
        )
        try assertRenderNotMatchTemplate(
            source: source,
            policy: .keepPublicBodiesElideOthers,
            unexpectedTemplate: #"var containsPublicOrOpen: Bool { «EMPTY» }"#
        )
    }

    /// Empty `{}` canonicalized to `{ /* empty */ }` unless keep-all; also assert rich sentinel appears for non-empty elisions.
    func testCanonicalizeEmptyBlocksOnlyWhenPolicyIsNotKeepAll() throws {
        let source = """
        struct Z {
            func empty() {}
            func nonEmpty() { print("Z") }
        }
        """
        // keep-all: raw braces preserved
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepAllBodiesLightlyCondensed,
            expectedTemplate: #"func empty() { }"#
        )
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepAllBodiesLightlyCondensed,
            expectedTemplate: #"func nonEmpty() { «ANY»Z«ANY» }"#
        )

        // keep-public: empty canonicalized; non-empty elided with sentinel
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepPublicBodiesElideOthers,
            expectedTemplate: #"func empty() { «EMPTY» }"#
        )
        try assertRenderContainsTemplate(
            source: source,
            policy: .keepPublicBodiesElideOthers,
            expectedTemplate: #"func nonEmpty() { «SENTINEL» }"#
        )
    }

    /// Compacts 3+ blank lines to 1 for text and unknown files.
    func testTextAndUnknownWhitespaceIsCompacted() throws {
        let textFile = AnalyzedFile(
            file: RepoFile(relativePath: "Notes.txt", absoluteURL: URL(fileURLWithPath: "/dev/null"), isDirectory: false, kind: .text, size: 0),
            text: "a\n\n\n b\n",
            declaredTypes: [], publicAPIScoreRaw: 0, referencedTypes: [:],
            complexity: 0, isEntrypoint: false, outgoingFileDeps: [], inboundRefCount: 0
        )
        let unknownFile = AnalyzedFile(
            file: RepoFile(relativePath: "blob.unknown", absoluteURL: URL(fileURLWithPath: "/dev/null"), isDirectory: false, kind: .unknown, size: 0),
            text: "x\n\n\n y\n",
            declaredTypes: [], publicAPIScoreRaw: 0, referencedTypes: [:],
            complexity: 0, isEntrypoint: false, outgoingFileDeps: [], inboundRefCount: 0
        )

        let textResult = try Renderer().render(file: ScoredFile(analyzed: textFile, score: 0.1, fanIn: 0, pageRank: 0.0), score: 0.1).content
        assertTextNotMatchTemplate(
            actual: textResult,
            unexpectedTemplate: "a\n\n\n b\n",
            source: textFile.text
        )
        assertTextMatchesTemplate(
            actual: textResult,
            expectedTemplate: "a\n\n b\n",
            source: textFile.text
        )

        let unknownResult = try Renderer().render(file: ScoredFile(analyzed: unknownFile, score: 0.2, fanIn: 0, pageRank: 0.0), score: 0.2).content
        assertTextNotMatchTemplate(
            actual: unknownResult,
            unexpectedTemplate: "x\n\n\n y\n",
            source: unknownFile.text
        )
        assertTextMatchesTemplate(
            actual: unknownResult,
            expectedTemplate: "x\n\n y\n",
            source: unknownFile.text
        )
    }

    /// Binary files show a size placeholder.
    func testBinaryFilesEmitSizePlaceholder() throws {
        let analyzed = AnalyzedFile(
            file: RepoFile(relativePath: "blob.dat", absoluteURL: URL(fileURLWithPath: "/dev/null"), isDirectory: false, kind: .binary, size: 1234),
            text: "",
            declaredTypes: [], publicAPIScoreRaw: 0, referencedTypes: [:],
            complexity: 0, isEntrypoint: false, outgoingFileDeps: [], inboundRefCount: 0
        )
        let scored = ScoredFile(analyzed: analyzed, score: 0.5, fanIn: 0, pageRank: 0)
        let content = try Renderer().render(file: scored, score: scored.score).content
        assertTextMatchesTemplate(
            actual: content,
            expectedTemplate: #"binary omitted; size=1234 bytes"#,
            source: "binary placeholder"
        )
    }

    // MARK: - New rendering coverage

    func testSubscriptAccessorsUseSentinelWhenElided() throws {
        let source = """
        struct S {
            subscript(i: Int) -> Int {
                get { i * 2 }
                set { _ = newValue }
            }
        }
        """
        try assertRenderContainsTemplate(
            source: source,
            policy: .signaturesOnly,
            expectedTemplate: #"subscript(«ANY») -> «ANY» { «SENTINEL» }"#
        )
    }

    func testDeinitUsesSentinelWhenElided() throws {
        let source = """
        final class C {
            deinit { print("BYE") }
        }
        """
        try assertRenderContainsTemplate(
            source: source,
            policy: .signaturesOnly,
            expectedTemplate: #"deinit { «SENTINEL» }"#
        )
    }
}
