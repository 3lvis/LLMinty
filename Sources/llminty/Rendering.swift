import Foundation
import SwiftParser
import SwiftSyntax

struct RenderedFile {
    let relativePath: String
    let content: String
}

final class Renderer {

    func render(file: ScoredFile, score: Double) throws -> RenderedFile {
        switch file.analyzed.file.kind {
        case .swift:
            let policy = policyFor(score: score)
            let content = try renderSwift(text: file.analyzed.text, policy: policy)
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: content)
        case .json:
            let reduced = JSONReducer.reduceJSONPreservingStructure(text: file.analyzed.text)
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: reduced)
        case .text, .unknown:
            let compact = compactText(file.analyzed.text)
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: compact)
        case .binary:
            let size = file.analyzed.file.size
            let type = (file.analyzed.file.relativePath as NSString).pathExtension.lowercased()
            let placeholder = "/* binary \(type.isEmpty ? "file" : type) — \(size) bytes (omitted) */\n"
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: placeholder)
        }
    }

    private func compactText(_ s: String) -> String { lightlyCondenseWhitespace(s) }

    // Remove trailing spaces; collapse 2+ blank lines to single blank; preserve content
    private func lightlyCondenseWhitespace(_ s: String) -> String {
        let lines = s.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        var out = String()
        out.reserveCapacity(s.count)
        var lastWasBlank = false
        for lineSub in lines {
            let line = String(lineSub).trimRightSpaces()
            let blank = line.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty
            if blank && lastWasBlank { continue }
            out += line
            // `split(whereSeparator:)` does not include the separator; recreate line endings
            out.append("\n")
            lastWasBlank = blank
        }
        return out
    }

    enum SwiftPolicy {
        case keepAllBodiesLightlyCondensed            // s ≥ 0.75
        case keepPublicBodiesElideOthers              // 0.50 ≤ s < 0.75
        case keepOneBodyPerTypeElideRest              // 0.25 ≤ s < 0.50
        case signaturesOnly                           // s < 0.25
    }

    func policyFor(score: Double) -> SwiftPolicy {
        if score >= 0.75 { return .keepAllBodiesLightlyCondensed }
        if score >= 0.50 { return .keepPublicBodiesElideOthers }
        if score >= 0.25 { return .keepOneBodyPerTypeElideRest }
        return .signaturesOnly
    }

    func renderSwift(text: String, policy: SwiftPolicy) throws -> String {
        let tree = Parser.parse(source: text)
        var plan = ElisionPlan(policy: policy)
        let planner = ElisionPlanner(plan: &plan)
        planner.walk(tree)

        // Build a single, combined list of edits, all based on ORIGINAL utf8 offsets.
        // Apply from highest -> lowest to keep remaining offsets valid.
        struct Edit { let range: Range<Int>; let replacement: String }
        var edits: [Edit] = []
        edits.reserveCapacity(plan.longBodyTrims.count + plan.elideRanges.count)
        edits.append(contentsOf: plan.longBodyTrims.map { Edit(range: $0.range, replacement: $0.replacement) })
        edits.append(contentsOf: plan.elideRanges.map { Edit(range: $0, replacement: " {...}\n") })
        edits.sort { $0.range.lowerBound > $1.range.lowerBound }

        var out = text
        let utf8Count = { (s: String) in s.utf8.count }

        // Helper: convert utf8 offset to String.Index safely, clamped in-bounds.
        func indexFromUTF8Offset(_ off: Int, in s: String) -> String.Index {
            let c = max(0, min(off, utf8Count(s)))
            let i8 = s.utf8.index(s.utf8.startIndex, offsetBy: c)
            // `within:` returns nil only if not on a character boundary; SwiftSyntax offsets are on boundaries.
            return String.Index(i8, within: s) ?? s.endIndex
        }

        for e in edits {
            // Validate original offsets against the current string length; since we go hi->lo,
            // earlier (lower) ranges remain valid after higher replacements.
            guard e.range.lowerBound <= e.range.upperBound else { continue }
            let start = indexFromUTF8Offset(e.range.lowerBound, in: out)
            let end   = indexFromUTF8Offset(e.range.upperBound, in: out)
            guard start <= end else { continue }
            out.replaceSubrange(start..<end, with: e.replacement)
        }

        return lightlyCondenseWhitespace(out)
    }
}

// MARK: - Planning

private struct ElisionPlan {
    let policy: Renderer.SwiftPolicy
    var elideRanges: [Range<Int>] = []
    struct Trim { let range: Range<Int>; let replacement: String }
    var longBodyTrims: [Trim] = []
}

private final class ElisionPlanner: SyntaxVisitor {
    private var typeStack: [String] = []
    private var plan: UnsafeMutablePointer<ElisionPlan>

    init(plan: inout ElisionPlan) {
        self.plan = withUnsafeMutablePointer(to: &plan) { $0 }
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { typeStack.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { _ = typeStack.popLast() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { typeStack.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: ClassDeclSyntax) { _ = typeStack.popLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { typeStack.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { _ = typeStack.popLast() }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { typeStack.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: ProtocolDeclSyntax) { _ = typeStack.popLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let body = node.body else { return .visitChildren }
        let isPublic = node.modifiers.containsPublicOrOpen
        handleBody(body: body, isPublic: isPublic)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let body = node.body else { return .visitChildren }
        let isPublic = node.modifiers.containsPublicOrOpen
        handleBody(body: body, isPublic: isPublic)
        return .visitChildren
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            // Accessors inherit visibility from the parent; assume not public here
            handleBody(body: body, isPublic: false)
        }
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        if let accessorBlock = node.accessorBlock {
            let isPublic = node.modifiers.containsPublicOrOpen
            switch accessorBlock.accessors {
            case .accessors(let list):
                for acc in list {
                    if let b = acc.body { handleBody(body: b, isPublic: isPublic) }
                }
            case .getter(_):
                break
            }
        }
        return .visitChildren
    }

    private func handleBody(body: CodeBlockSyntax, isPublic: Bool) {
        let lb = body.leftBrace.position.utf8Offset
        let rb = body.rightBrace.endPosition.utf8Offset
        let range = lb..<rb
        switch plan.pointee.policy {
        case .keepAllBodiesLightlyCondensed:
            // Keep everything; but if a single body is extremely long, trim middle lines
            if rb - lb > 800 {
                plan.pointee.longBodyTrims.append(.init(range: range, replacement: " { /* trimmed */ }"))
            }
        case .keepPublicBodiesElideOthers:
            if !isPublic { plan.pointee.elideRanges.append(range) }
        case .keepOneBodyPerTypeElideRest:
            // Keep the first body per type, elide others
            if seenTypeBody(typeStack.joined(separator: ".")) {
                plan.pointee.elideRanges.append(range)
            }
        case .signaturesOnly:
            plan.pointee.elideRanges.append(range)
        }
    }

    // Simple memoization: one kept body per fully-qualified type name
    private var kept: Set<String> = []
    private func seenTypeBody(_ typeName: String) -> Bool {
        if kept.contains(typeName) { return true }
        kept.insert(typeName)
        return false
    }
}

// MARK: - Small helpers

private extension String {
    func trimRightSpaces() -> String {
        var s = self
        while s.last == " " { _ = s.removeLast() }
        return s
    }
}

private extension DeclModifierListSyntax {
    var containsPublicOrOpen: Bool {
        for m in self {
            let k = m.name.text
            if k == "public" || k == "open" { return true }
        }
        return false
    }
}
private extension Optional where Wrapped == DeclModifierListSyntax {
    var containsPublicOrOpen: Bool { self?.containsPublicOrOpen ?? false }
}
