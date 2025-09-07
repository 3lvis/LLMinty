import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - Types used by the rest of the package

struct RenderedFile {
    let relativePath: String
    let content: String
}

final class Renderer {

    enum RenderPolicy {
        case signaturesOnly
        case keepOneBodyPerTypeElideRest
        case keepPublicBodiesElideOthers
        case keepAllBodiesLightlyCondensed
    }

    // MARK: Entry points

    func render(file: ScoredFile, score: Double) throws -> RenderedFile {
        let policy = policyFor(score: score)
        switch file.analyzed.file.kind {
        case .swift:
            let text = try renderSwift(text: file.analyzed.text, policy: policy)
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: text)
        case .text, .unknown, .json:
            let text = Renderer.compactText(file.analyzed.text)
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: text)
        case .binary:
            // Plain, no comment wrappers — tests look for this exact token.
            let text = "binary omitted; size=\(file.analyzed.file.size) bytes"
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: text)
        }
    }

    func renderSwift(text: String, policy: RenderPolicy) throws -> String {
        let tree = Parser.parse(source: text)
        let rewriter = ElideBodiesRewriter(policy: policy)
        let rewritten = rewriter.visit(tree)
        let out = rewritten.description
        // For keep-all, do NOT canonicalize empties; for others, normalize `{} -> { /* empty */ }`.
        if policy == .keepAllBodiesLightlyCondensed {
            return out
        } else {
            return canonicalizeEmptyBlocks(out)
        }
    }

    // Score -> policy mapping (inclusive boundaries)
    func policyFor(score: Double) -> RenderPolicy {
        switch score {
        case let s where s >= 0.8: return .keepAllBodiesLightlyCondensed
        case let s where s >= 0.6: return .keepPublicBodiesElideOthers
        case let s where s >= 0.3: return .keepOneBodyPerTypeElideRest
        default: return .signaturesOnly
        }
    }

    // MARK: - Text utilities

    /// Compacts 3+ blank lines to 1.
    static func compactText(_ s: String) -> String {
        // Normalize CRLF and CR
        let unified = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Replace 3+ newlines with 2 (i.e., one blank line)
        let regex = try! NSRegularExpression(pattern: "\n{3,}", options: [])
        let range = NSRange(unified.startIndex..<unified.endIndex, in: unified)
        return regex.stringByReplacingMatches(in: unified, options: [], range: range, withTemplate: "\n\n")
    }

    /// Only used for non-keepAll policies.
    private func canonicalizeEmptyBlocks(_ s: String) -> String {
        // Replace `{}` (possibly with internal whitespace) with `{ /* empty */ }`
        let pattern = #"\{\s*\}"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "{ /* empty */ }")
    }
}

// MARK: - Rewriter

fileprivate final class ElideBodiesRewriter: SyntaxRewriter {

    private let policy: Renderer.RenderPolicy

    // Track "keep-one" per container (type or extension).
    private var containerStack: [String] = []
    private var keptOne: Set<String> = []

    init(policy: Renderer.RenderPolicy) {
        self.policy = policy
        super.init(viewMode: .sourceAccurate)
    }

    // Container bookkeeping

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        withContainer(name: "struct \(node.name.text)") {
            let newMembers = visit(node.memberBlock)
            var n = node
            n.memberBlock = newMembers
            return DeclSyntax(n)
        }
    }

    override func visit(_ node: ClassDeclSyntax) -> DeclSyntax {
        withContainer(name: "class \(node.name.text)") {
            let newMembers = visit(node.memberBlock)
            var n = node
            n.memberBlock = newMembers
            return DeclSyntax(n)
        }
    }

    override func visit(_ node: EnumDeclSyntax) -> DeclSyntax {
        withContainer(name: "enum \(node.name.text)") {
            let newMembers = visit(node.memberBlock)
            var n = node
            n.memberBlock = newMembers
            return DeclSyntax(n)
        }
    }

    override func visit(_ node: ExtensionDeclSyntax) -> DeclSyntax {
        let name = node.extendedType.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return withContainer(name: "extension \(name)") {
            let newMembers = visit(node.memberBlock)
            var n = node
            n.memberBlock = newMembers
            return DeclSyntax(n)
        }
    }

    // MARK: - Function-like

    override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
        guard let body = node.body else { return DeclSyntax(node) }

        switch policy {
        case .keepAllBodiesLightlyCondensed:
            return DeclSyntax(node)
        case .keepPublicBodiesElideOthers:
            if isPublicOrOpen(node.modifiers) { return DeclSyntax(node) }
            return DeclSyntax(parseDeclReplacingBody(of: node, withSentinelFor: body))
        case .keepOneBodyPerTypeElideRest:
            if markFirstIfNeeded() { return DeclSyntax(node) }
            return DeclSyntax(parseDeclReplacingBody(of: node, withSentinelFor: body))
        case .signaturesOnly:
            return DeclSyntax(parseDeclReplacingBody(of: node, withSentinelFor: body))
        }
    }

    override func visit(_ node: InitializerDeclSyntax) -> DeclSyntax {
        guard let body = node.body else { return DeclSyntax(node) }
        switch policy {
        case .keepAllBodiesLightlyCondensed:
            return DeclSyntax(node)
        case .keepPublicBodiesElideOthers:
            if isPublicOrOpen(node.modifiers) { return DeclSyntax(node) }
            return DeclSyntax(parseDeclReplacingBody(of: node, withSentinelFor: body))
        case .keepOneBodyPerTypeElideRest:
            if markFirstIfNeeded() { return DeclSyntax(node) }
            return DeclSyntax(parseDeclReplacingBody(of: node, withSentinelFor: body))
        case .signaturesOnly:
            return DeclSyntax(parseDeclReplacingBody(of: node, withSentinelFor: body))
        }
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> DeclSyntax {
        switch policy {
        case .keepAllBodiesLightlyCondensed:
            return DeclSyntax(node)
        case .keepPublicBodiesElideOthers, .keepOneBodyPerTypeElideRest, .signaturesOnly:
            // deinit has no modifiers; policy != keepAll => elide
            return DeclSyntax(parseDeclReplacingBody(of: node, withSentinelForLines: 1))
        }
    }

    override func visit(_ node: SubscriptDeclSyntax) -> DeclSyntax {
        guard let accessor = node.accessorBlock else { return DeclSyntax(node) }
        switch policy {
        case .keepAllBodiesLightlyCondensed:
            return DeclSyntax(node)
        case .keepPublicBodiesElideOthers:
            if isPublicOrOpen(node.modifiers) { return DeclSyntax(node) }
            return DeclSyntax(parseDeclReplacingAccessor(of: node, accessor: accessor))
        case .keepOneBodyPerTypeElideRest:
            // Accessors DO NOT count toward keep-one; always elide under keep-one.
            return DeclSyntax(parseDeclReplacingAccessor(of: node, accessor: accessor))
        case .signaturesOnly:
            return DeclSyntax(parseDeclReplacingAccessor(of: node, accessor: accessor))
        }
    }

    override func visit(_ node: VariableDeclSyntax) -> DeclSyntax {
        // Only computed properties (with accessor block) are interesting.
        guard let binding = node.bindings.first, let accessor = binding.accessorBlock else {
            return DeclSyntax(node)
        }

        switch policy {
        case .keepAllBodiesLightlyCondensed:
            return DeclSyntax(node)
        case .keepPublicBodiesElideOthers:
            if isPublicOrOpen(node.modifiers) { return DeclSyntax(node) }
            return DeclSyntax(parseDeclReplacingAccessor(of: node, accessor: accessor))
        case .keepOneBodyPerTypeElideRest:
            // Accessors DO NOT count toward the one; always elide under keep-one.
            return DeclSyntax(parseDeclReplacingAccessor(of: node, accessor: accessor))
        case .signaturesOnly:
            return DeclSyntax(parseDeclReplacingAccessor(of: node, accessor: accessor))
        }
    }

    // MARK: - Helpers

    private func withContainer<T>(name: String, _ body: () -> T) -> T {
        containerStack.append(name)
        defer { _ = containerStack.popLast() }
        return body()
    }

    private func markFirstIfNeeded() -> Bool {
        guard let current = containerStack.last else { return true /* outside types: keep */ }
        if keptOne.contains(current) {
            return false
        } else {
            keptOne.insert(current)
            return true
        }
    }

    private func isPublicOrOpen(_ modifiers: DeclModifierListSyntax?) -> Bool {
        guard let mods = modifiers else { return false }
        for m in mods {
            let t = m.name.text
            if t == "public" || t == "open" { return true }
        }
        return false
    }

    // Build sentinel comment using line count + short hash of the original body text.
    private func sentinel(lines: Int, for text: String) -> String {
        let h = Self.fnv1a64(text)
        var hex = String(h & 0x000000ffffffffff, radix: 16) // up to 56 bits
        if hex.count < 10 { hex = String(repeating: "0", count: 10 - hex.count) + hex }
        if hex.count > 12 { hex = String(hex.prefix(12)) }
        return "/* elided-implemented; lines=\(max(1, lines)); h=\(hex) */"
    }

    // Replace function/init/deinit by re-parsing the signature and attaching a simple body.
    private func parseDeclReplacingBody(of fn: FunctionDeclSyntax, withSentinelFor body: CodeBlockSyntax) -> DeclSyntax {
        let sig = fn.with(\.body, nil).description.trimmingCharacters(in: .whitespacesAndNewlines)
        let (lines, text) = Self.bodyStats(from: body)
        let newText = "\(sig) { \(sentinel(lines: lines, for: text)) }"
        let parsed = Parser.parse(source: newText)
        for item in parsed.statements {
            if let d = item.item.as(DeclSyntax.self) { return d }
        }
        return DeclSyntax(fn)
    }

    private func parseDeclReplacingBody(of ini: InitializerDeclSyntax, withSentinelFor body: CodeBlockSyntax) -> DeclSyntax {
        let sig = ini.with(\.body, nil).description.trimmingCharacters(in: .whitespacesAndNewlines)
        let (lines, text) = Self.bodyStats(from: body)
        let newText = "\(sig) { \(sentinel(lines: lines, for: text)) }"
        let parsed = Parser.parse(source: newText)
        for item in parsed.statements {
            if let d = item.item.as(DeclSyntax.self) { return d }
        }
        return DeclSyntax(ini)
    }

    private func parseDeclReplacingBody(of deinitDecl: DeinitializerDeclSyntax, withSentinelForLines lines: Int) -> DeclSyntax {
        let sig = deinitDecl.with(\.body, nil).description.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = deinitDecl.body?.description ?? ""
        let newText = "\(sig) { \(sentinel(lines: lines, for: text)) }"
        let parsed = Parser.parse(source: newText)
        for item in parsed.statements {
            if let d = item.item.as(DeclSyntax.self) { return d }
        }
        return DeclSyntax(deinitDecl)
    }

    private func parseDeclReplacingAccessor(of sub: SubscriptDeclSyntax, accessor: AccessorBlockSyntax) -> DeclSyntax {
        let head = sub.with(\.accessorBlock, nil).description.trimmingCharacters(in: .whitespacesAndNewlines)
        let (lines, text) = Self.accessorStats(from: accessor)
        let newText = "\(head) { \(sentinel(lines: lines, for: text)) }"
        let parsed = Parser.parse(source: newText)
        for item in parsed.statements {
            if let d = item.item.as(DeclSyntax.self) { return d }
        }
        return DeclSyntax(sub)
    }

    private func parseDeclReplacingAccessor(of varDecl: VariableDeclSyntax, accessor: AccessorBlockSyntax) -> DeclSyntax {
        // Only handle single-binding vars for simplicity (common for properties in tests).
        guard varDecl.bindings.count == 1, let b0 = varDecl.bindings.first else { return DeclSyntax(varDecl) }

        // Rebuild the "head" (attributes + modifiers + let/var) without bindings,
        // avoiding removed SyntaxFactory APIs.
        let attrs = varDecl.attributes.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let mods  = varDecl.modifiers.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec  = varDecl.bindingSpecifier.text
        let headParts = [attrs, mods, spec].filter { !$0.isEmpty }
        let head = headParts.joined(separator: " ")

        // Pattern + (optional) type annotation + sentinel accessor block.
        let pat = b0.pattern.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeAnn = b0.typeAnnotation?.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let (lines, text) = Self.accessorStats(from: accessor)

        let bindingText = "\(pat)\(typeAnn.isEmpty ? "" : " \(typeAnn)") { \(sentinel(lines: lines, for: text)) }"
        let newText = "\(head) \(bindingText)"

        let parsed = Parser.parse(source: newText)
        for item in parsed.statements {
            if let d = item.item.as(DeclSyntax.self) { return d }
        }
        return DeclSyntax(varDecl)
    }

    // MARK: - Hashing / stats

    private static func bodyStats(from block: CodeBlockSyntax) -> (lines: Int, text: String) {
        let raw = block.statements.description
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = max(1, trimmed.split(whereSeparator: \.isNewline).count)
        return (lineCount, trimmed)
    }

    private static func accessorStats(from accessor: AccessorBlockSyntax) -> (lines: Int, text: String) {
        let inner = accessor.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = max(1, inner.split(whereSeparator: \.isNewline).count)
        return (lineCount, inner)
    }

    private static func fnv1a64(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x00000100000001B3
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash = hash &* prime
        }
        return hash
    }
}
