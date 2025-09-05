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

    private func compactText(_ s: String) -> String {
        lightlyCondenseWhitespace(s)
    }

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
            if lineSub.last?.isNewline == true { out.append("\n") }
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

        // Build resulting text by splicing ranges
        var out = text

        // Apply very-long body trims first (for keep policies), then elisions.
        for trim in plan.longBodyTrims.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let start = out.index(out.startIndex, offsetBy: trim.range.lowerBound)
            let end   = out.index(out.startIndex, offsetBy: trim.range.upperBound)
            out.replaceSubrange(start..<end, with: trim.replacement)
        }

        for r in plan.elideRanges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            let start = out.index(out.startIndex, offsetBy: r.lowerBound)
            let end   = out.index(out.startIndex, offsetBy: r.upperBound)
            out.replaceSubrange(start..<end, with: " {...}\n")
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
