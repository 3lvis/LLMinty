import Foundation
import XCTest
@testable import llminty

final class RenderingTests: XCTestCase {

    // Minimal, local regex helpers (pure XCTest; no external test utilities).
    private static let sentinelPattern = #"/\*\s*elided-implemented;\s*lines=\d+;\s*h=[0-9a-f]{8,12}\s*\*/"#
    private static let emptyPattern     = #"/\*\s*empty\s*\*/"#

    private func assertMatches(_ text: String, pattern: String, file: StaticString = #filePath, line: UInt = #line) {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(text.startIndex..., in: text)
        let ok = regex.firstMatch(in: text, options: [], range: range) != nil
        XCTAssertTrue(ok, """
        Expected to match regex:
        
        \(pattern)
        
        In text:
        
        \(text)
        """, file: file, line: line)
    }

    private func assertNotMatches(_ text: String, pattern: String, file: StaticString = #filePath, line: UInt = #line) {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(text.startIndex..., in: text)
        let ok = regex.firstMatch(in: text, options: [], range: range) == nil
        XCTAssertTrue(ok, """
        Expected NOT to match regex, but it did:
        
        \(pattern)
        
        In text:
        
        \(text)
        """, file: file, line: line)
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
        let out = try Renderer().renderSwift(text: source, policy: .signaturesOnly)
        let pattern = #"func\s+recompute\(\s*_?\s*n\s*:\s*Int\s*\)\s*->\s*Int\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#
        assertMatches(out, pattern: pattern)
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
        let rx = try! NSRegularExpression(pattern: capture)
        func grab(_ s: String) -> String? {
            let r = NSRange(s.startIndex..., in: s)
            return rx.firstMatch(in: s, options: [], range: r).map { (s as NSString).substring(with: $0.range(at: 1)) }
        }
        guard let h1 = grab(first), let h2 = grab(second) else {
            return XCTFail("expected short hash in both renders")
        }
        XCTAssertEqual(h1, h2)
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
            assertMatches(content, pattern: #"public\s+func\s+keepMe\([^\)]*\)\s*\{\s*(?s:.*)PUBLIC_BODY(?s:.*)\}"#)
            assertMatches(content, pattern: #"\bfunc\s+dropMe\([^\)]*\)\s*\{\s*(?s:.*)INTERNAL_BODY(?s:.*)\}"#)
        }

        // keepPublic: public body kept; internal elided
        do {
            let content = try renderer.render(file: ScoredFile(analyzed: analyzed, score: 0.65, fanIn: 0, pageRank: 0), score: 0.65).content
            assertMatches(content, pattern: #"public\s+func\s+keepMe\([^\)]*\)\s*\{\s*(?s:.*)PUBLIC_BODY(?s:.*)\}"#)
            assertMatches(content, pattern: #"\bfunc\s+dropMe\([^\)]*\)\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
        }

        // signaturesOnly: both elided
        do {
            let content = try renderer.render(file: ScoredFile(analyzed: analyzed, score: 0.25, fanIn: 0, pageRank: 0), score: 0.25).content
            assertMatches(content, pattern: #"public\s+func\s+keepMe\([^\)]*\)\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
            assertMatches(content, pattern: #"\bfunc\s+dropMe\([^\)]*\)\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
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
        let out = try Renderer().renderSwift(text: source, policy: .keepAllBodiesLightlyCondensed)
        assertMatches(out, pattern: #"\bfunc\s+empty\(\)\s*\{\s*\}"#)
        assertMatches(out, pattern: #"\bfunc\s+nonEmpty\(\)\s*\{\s*(?s:.*)X(?s:.*)\}"#)
    }

    /// Under keep-public, `open` kept; `internal`/`package` elided with rich sentinel; truly empty becomes `{ /* empty */ }`.
    func testOpenIsKept_InternalAndPackageAreElided() throws {
        let source = """
        open class OC { open func of() { print("O") } }
        struct IC { func i() { print("I") } }
        package func pkg() { print("P") }
        """
        let out = try Renderer().renderSwift(text: source, policy: .keepPublicBodiesElideOthers)

        // open kept
        assertMatches(out, pattern: #"open\s+func\s+of\([^\)]*\)\s*\{\s*(?s:.*)O(?s:.*)\}"#)
        // internal elided
        assertMatches(out, pattern: #"\bfunc\s+i\([^\)]*\)\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
        // package elided
        assertMatches(out, pattern: #"\bpackage\s+func\s+pkg\([^\)]*\)\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
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
        let out = try Renderer().renderSwift(text: source, policy: .keepOneBodyPerTypeElideRest)
        assertMatches(out, pattern: #"\binit\(\)\s*\{\s*(?s:.*)FIRST(?s:.*)\}"#)
        assertMatches(out, pattern: #"\bfunc\s+second\([^\)]*\)\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
        assertMatches(out, pattern: #"\bfunc\s+third\([^\)]*\)\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
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
        let out = try Renderer().renderSwift(text: source, policy: .keepOneBodyPerTypeElideRest)
        assertMatches(out, pattern: #"\bvar\s+v\s*:\s*Int\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
        assertMatches(out, pattern: #"\bfunc\s+kept\([^\)]*\)\s*\{\s*(?s:.*)KEPT(?s:.*)\}"#)
        assertMatches(out, pattern: #"\bfunc\s+elided\([^\)]*\)\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
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
        let out = try Renderer().renderSwift(text: source, policy: .keepOneBodyPerTypeElideRest)

        // struct E { e1 kept; e2 elided }
        assertMatches(out, pattern: #"\bfunc\s+e1\([^\)]*\)\s*\{\s*(?s:.*)E1(?s:.*)\}"#)
        assertMatches(out, pattern: #"\bfunc\s+e2\([^\)]*\)\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)

        // extension E { x1 kept; x2 elided }
        assertMatches(out, pattern: #"\bextension\s+E\b(?s:.*)\bfunc\s+x1\([^\)]*\)\s*\{\s*(?s:.*)X1(?s:.*)\}"#)
        assertMatches(out, pattern: #"\bextension\s+E\b(?s:.*)\bfunc\s+x2\([^\)]*\)\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
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
        do {
            let out = try Renderer().renderSwift(text: internalSource, policy: .signaturesOnly)
            assertMatches(out, pattern: #"\bvar\s+value\s*:\s*Int\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
        }
        do {
            let out = try Renderer().renderSwift(text: internalSource, policy: .keepPublicBodiesElideOthers)
            assertMatches(out, pattern: #"\bvar\s+value\s*:\s*Int\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
        }

        let publicSource = """
        public struct A {
            public var value: Int {
                get { 1 }
                set { _ = newValue + 1 }
            }
        }
        """
        do {
            let out = try Renderer().renderSwift(text: publicSource, policy: .keepPublicBodiesElideOthers)
            // Ensure the property is NOT elided (no sentinel at that site).
            assertNotMatches(out, pattern: #"\bvar\s+value\s*:\s*Int\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
        }
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
        let out = try Renderer().renderSwift(text: source, policy: .keepPublicBodiesElideOthers)
        assertMatches(out, pattern: #"\bvar\s+containsPublicOrOpen\s*:\s*Bool\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
        assertNotMatches(out, pattern: #"\bvar\s+containsPublicOrOpen\s*:\s*Bool\s*\{\s*\#(RenderingTests.emptyPattern)\s*\}"#)
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
        do {
            let out = try Renderer().renderSwift(text: source, policy: .keepAllBodiesLightlyCondensed)
            assertMatches(out, pattern: #"\bfunc\s+empty\(\)\s*\{\s*\}"#)
            assertMatches(out, pattern: #"\bfunc\s+nonEmpty\(\)\s*\{\s*(?s:.*)Z(?s:.*)\}"#)
        }

        // keep-public: empty canonicalized; non-empty elided with sentinel
        do {
            let out = try Renderer().renderSwift(text: source, policy: .keepPublicBodiesElideOthers)
            assertMatches(out, pattern: #"\bfunc\s+empty\(\)\s*\{\s*\#(RenderingTests.emptyPattern)\s*\}"#)
            assertMatches(out, pattern: #"\bfunc\s+nonEmpty\(\)\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
        }
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
        XCTAssertNotEqual(textResult, "a\n\n\n b\n")
        XCTAssertEqual(textResult, "a\n\n b\n")

        let unknownResult = try Renderer().render(file: ScoredFile(analyzed: unknownFile, score: 0.2, fanIn: 0, pageRank: 0.0), score: 0.2).content
        XCTAssertNotEqual(unknownResult, "x\n\n\n y\n")
        XCTAssertEqual(unknownResult, "x\n\n y\n")
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
        XCTAssertEqual(content, "binary omitted; size=1234 bytes")
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
        let out = try Renderer().renderSwift(text: source, policy: .signaturesOnly)
        let pattern = #"\bsubscript\([\s\S]*?\)\s*->\s*[\s\S]*?\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#
        assertMatches(out, pattern: pattern)
    }

    func testDeinitUsesSentinelWhenElided() throws {
        let source = """
        final class C {
            deinit { print("BYE") }
        }
        """
        let out = try Renderer().renderSwift(text: source, policy: .signaturesOnly)
        assertMatches(out, pattern: #"\bdeinit\s*\{\s*\#(RenderingTests.sentinelPattern)\s*\}"#)
    }

    // MARK: - Trivia & sentinel rawness regression guards

    /// Do not glue closing braces to subsequent `// MARK:` lines or next decls.
    // Replace this whole test in RenderingTests.swift
    func testPreservesTriviaAroundMarksAndBetweenDecls() throws {
        let source = """
    // MARK: - Parser
    private func parse() { print("A") }
    
    // MARK: - Eval
    func eval() { print("B") }
    """
        let out = try Renderer().renderSwift(text: source, policy: .signaturesOnly)

        // First MARK can be at start-of-file; must begin on its own line.
        assertMatches(out, pattern: #"(?m)^//\s*MARK:\s*-\s*Parser"#)
        // Second MARK must be on a new line after the closing brace of the previous decl.
        assertMatches(out, pattern: #"\}\s*\R//\s*MARK:\s*-\s*Eval"#)

        // Never same-line glue: `} // MARK:` or `}// MARK:` (no newline between).
        assertNotMatches(out, pattern: #"\}[ \t]*//\s*MARK:"#)
        assertNotMatches(out, pattern: #"\}//\s*MARK:"#)

        // After each MARK, the following decl must start on the next line.
        assertMatches(out, pattern: #"//\s*MARK:\s*-\s*Parser\R\s*private\s+func\s+parse\("#)
        assertMatches(out, pattern: #"//\s*MARK:\s*-\s*Eval\R\s*func\s+eval\("#)

        // And guard against historical glue `}private` / `}func` (no newline).
        assertNotMatches(out, pattern: #"\}[ \t]*private\s+func"#)
        assertNotMatches(out, pattern: #"\}[ \t]*func\s+[A-Za-z_]"#)
    }

    /// The sentinel must be computed from the *exact* body text, including blank lines.
    func testSentinelUsesExactBodyTextForLinesAndHash() throws {
        // Compact body: two statements, no blank line between.
        let compact = """
        func x() {
            print(1)
            print(2)
        }
        """
        // Spaced body: identical but with one blank line between statements.
        let spaced = """
        func x() {
            print(1)
        
            print(2)
        }
        """

        let outCompact = try Renderer().renderSwift(text: compact, policy: .signaturesOnly)
        let outSpaced  = try Renderer().renderSwift(text: spaced,  policy: .signaturesOnly)

        // Extract lines and hash from the sentinel comment.
        let rx = try! NSRegularExpression(pattern: #"lines=(\d+);\s*h=([0-9a-f]{8,12})"#, options: [])
        func extract(_ s: String) -> (lines: Int, hash: String) {
            let range = NSRange(s.startIndex..., in: s)
            guard let m = rx.firstMatch(in: s, options: [], range: range) else {
                XCTFail("no sentinel found in: \(s)")
                return (0, "")
            }
            let linesStr = (s as NSString).substring(with: m.range(at: 1))
            let hashStr  = (s as NSString).substring(with: m.range(at: 2))
            return (Int(linesStr) ?? -1, hashStr)
        }

        let a = extract(outCompact)
        let b = extract(outSpaced)

        // Adding one blank line should increase the reported line count and change the hash.
        XCTAssertGreaterThan(b.lines, a.lines, "Expected extra blank line to increase lines= in sentinel")
        XCTAssertNotEqual(a.hash, b.hash, "Expected different h= when body text differs by blank line")
    }
}
