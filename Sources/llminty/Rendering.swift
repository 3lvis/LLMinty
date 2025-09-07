// Sources/llminty/Rendering.swift
import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - Output model

struct RenderedFile {
    let relativePath: String
    let content: String
    init(relativePath: String, content: String) {
        self.relativePath = relativePath
        self.content = content
    }
}

// MARK: - Renderer

final class Renderer {
    // Rendering policy
    enum RenderPolicy: Equatable {
        case keepAllBodiesLightlyCondensed          // keep all bodies (then lightly condense)
        case keepPublicBodiesElideOthers            // keep public/open bodies; elide the rest
        case keepOneBodyPerTypeElideRest            // keep one executable body per type; elide others
        case signaturesOnly                         // elide all bodies (use rich sentinel)
    }

    /// Map a 0–1 score to a rendering policy (matches tests’ expectations).
    func policyFor(score: Double) -> RenderPolicy {
        switch score {
        case let s where s >= 0.80: return .keepAllBodiesLightlyCondensed
        case let s where s >= 0.60: return .keepPublicBodiesElideOthers
        case let s where s >= 0.30: return .keepOneBodyPerTypeElideRest
        default:                    return .signaturesOnly
        }
    }

    /// Render a single file based on its kind.
    func render(file: ScoredFile, score: Double) throws -> RenderedFile {
        switch file.analyzed.file.kind {
        case .swift:
            let policy = policyFor(score: score)
            let content = try renderSwift(text: file.analyzed.text, policy: policy)
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: content)

        case .json:
            // Preserve structure but trim big payloads; then lightly condense
            let reduced = JSONReducer.reduceJSONPreservingStructure(text: file.analyzed.text)
            return RenderedFile(relativePath: file.analyzed.file.relativePath,
                                content: lightlyCondenseWhitespace(reduced))

        case .text, .unknown:
            // Line-aware compaction expected by tests
            return RenderedFile(relativePath: file.analyzed.file.relativePath,
                                content: lightlyCondenseWhitespace(file.analyzed.text))

        case .binary:
            // Snapshot E2E expects a visible placeholder
            let bytes = file.analyzed.file.size
            let placeholder = "/* binary omitted; size=\(bytes) bytes */"
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: placeholder)
        }
    }

    // MARK: - Swift rendering

    /// Produces Swift text according to policy. Uses SwiftSyntax to optionally elide bodies while keeping signatures.
    func renderSwift(text: String, policy: RenderPolicy) throws -> String {
        let source = Parser.parse(source: text)
        let rw = ElideBodiesRewriter(policy: policy)
        let rewritten = rw.visit(source)
        var result = rewritten.description

        // Canonicalize truly empty blocks ("{}") to "{ ... }" for stability.
        // (Rich sentinel blocks are not empty and are left intact.)
        if policy != .keepAllBodiesLightlyCondensed {
            let regex = try! NSRegularExpression(pattern: #"\{\s*\}"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "{ ... }"
            )
        }

        return lightlyCondenseWhitespace(result)
    }

    // MARK: - Whitespace condensation (stable & deterministic)

    private func lightlyCondenseWhitespace(_ s: String) -> String {
        // Normalize newlines first
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n")
        // Split but keep empty subsequences so we can reason about blank lines
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        var outLines: [String] = []
        outLines.reserveCapacity(rawLines.count)

        var prevWasBlank = false
        for lineSub in rawLines {
            // Trim trailing spaces/tabs only (preserve leading spaces)
            var line = String(lineSub)
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }

            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank {
                // Keep at most one consecutive blank line
                if !prevWasBlank { outLines.append(""); prevWasBlank = true }
            } else {
                outLines.append(line)
                prevWasBlank = false
            }
        }
        return outLines.joined(separator: "\n")
    }
}

// MARK: - SwiftSyntax Rewriter with elision logic

fileprivate final class ElideBodiesRewriter: SyntaxRewriter {
    private let policy: Renderer.RenderPolicy

    // Track current container (type or <toplevel>) to support keepOneBodyPerTypeElideRest
    private var typeStack: [String] = []
    private var keptOneByContainer = Set<String>()

    init(policy: Renderer.RenderPolicy) {
        self.policy = policy
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Sentinel helpers

    /// `/* elided-implemented; lines=<N>; h=<short-hex> */`
    private func sentinelComment(lines: Int, hash: String) -> String {
        return "/* elided-implemented; lines=\(lines); h=\(hash) */"
    }

    /// FNV-1a 64-bit short hex (first 10 chars) — tiny, deterministic.
    private func shortHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { hash ^= UInt64(b); hash &*= 0x100000001b3 }
        return String(hash, radix: 16).prefix(10).lowercased()
    }

    private func bodyStats(from body: CodeBlockSyntax) -> (lines: Int, hash: String) {
        let text = body.statements.description
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return (lines, shortHash(text.replacingOccurrences(of: "\r\n", with: "\n")))
    }

    /// `{ /* elided-implemented; lines=…; h=… */ }` with zero statements
    private func makeSentinelBlock(from body: CodeBlockSyntax) -> CodeBlockSyntax {
        let stats = bodyStats(from: body)
        let lb = TokenSyntax.leftBraceToken(trailingTrivia: .spaces(1) + .blockComment(sentinelComment(lines: stats.lines, hash: stats.hash)) + .spaces(1))
        return CodeBlockSyntax(leftBrace: lb,
                               statements: CodeBlockItemListSyntax([]),
                               rightBrace: .rightBraceToken())
    }

    /// "{}" (later canonicalized to "{ ... }")
    private func makeEmptyBlock() -> CodeBlockSyntax {
        CodeBlockSyntax(leftBrace: .leftBraceToken(),
                        statements: CodeBlockItemListSyntax([]),
                        rightBrace: .rightBraceToken())
    }

    private func containerKey() -> String { typeStack.last ?? "<toplevel>" }

    // Pure decision (no mutation)
    private func shouldElide(isPublic: Bool) -> Bool {
        switch policy {
        case .keepAllBodiesLightlyCondensed:
            return false
        case .keepPublicBodiesElideOthers:
            return !isPublic
        case .keepOneBodyPerTypeElideRest:
            // Decision deferred to each decl visitor; default is "maybe", but we return false here
            // and handle mutation/counting per decl kind to enforce priority.
            return false
        case .signaturesOnly:
            return true
        }
    }

    private func isPublicOrOpen(_ modifiers: DeclModifierListSyntax?) -> Bool {
        guard let mods = modifiers else { return false }
        for m in mods {
            switch m.name.tokenKind {
            case .keyword(.public), .keyword(.open):
                return true
            default: break
            }
        }
        return false
    }

    // MARK: - Container tracking

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        typeStack.append(node.name.text); defer { _ = typeStack.popLast() }
        return DeclSyntax(super.visit(node))
    }
    override func visit(_ node: ClassDeclSyntax) -> DeclSyntax {
        typeStack.append(node.name.text); defer { _ = typeStack.popLast() }
        return DeclSyntax(super.visit(node))
    }
    override func visit(_ node: EnumDeclSyntax) -> DeclSyntax {
        typeStack.append(node.name.text); defer { _ = typeStack.popLast() }
        return DeclSyntax(super.visit(node))
    }
    override func visit(_ node: ActorDeclSyntax) -> DeclSyntax {
        typeStack.append(node.name.text); defer { _ = typeStack.popLast() }
        return DeclSyntax(super.visit(node))
    }
    override func visit(_ node: ExtensionDeclSyntax) -> DeclSyntax {
        let name = node.extendedType.trimmedDescription
        typeStack.append("ext \(name)"); defer { _ = typeStack.popLast() }
        return DeclSyntax(super.visit(node))
    }

    // MARK: - Policy helpers for "keep one per type"

    private func shouldKeepOneHere(kindCountsAsExecutable: Bool) -> Bool {
        guard policy == .keepOneBodyPerTypeElideRest else { return true }
        let key = containerKey()
        if keptOneByContainer.contains(key) {
            return false
        } else {
            if kindCountsAsExecutable {
                keptOneByContainer.insert(key) // mark only for executable decls (func/init/subscript/deinit)
            }
            return kindCountsAsExecutable
        }
    }

    // MARK: - Functions / inits / deinits

    override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
        guard let body = node.body else { return DeclSyntax(super.visit(node)) }
        let pub = isPublicOrOpen(node.modifiers)

        switch policy {
        case .keepOneBodyPerTypeElideRest:
            if shouldKeepOneHere(kindCountsAsExecutable: true) {
                return DeclSyntax(super.visit(node)) // keep body
            } else {
                let newBody = makeEmptyBlock()
                return DeclSyntax(node.with(\.body, newBody))
            }

        default:
            if shouldElide(isPublic: pub) {
                let newBody = (policy == .signaturesOnly) ? makeSentinelBlock(from: body) : makeEmptyBlock()
                return DeclSyntax(node.with(\.body, newBody))
            }
            return DeclSyntax(super.visit(node))
        }
    }

    override func visit(_ node: InitializerDeclSyntax) -> DeclSyntax {
        guard let body = node.body else { return DeclSyntax(super.visit(node)) }
        let pub = isPublicOrOpen(node.modifiers)

        switch policy {
        case .keepOneBodyPerTypeElideRest:
            if shouldKeepOneHere(kindCountsAsExecutable: true) {
                return DeclSyntax(super.visit(node)) // keep body (prefer inits when first seen)
            } else {
                let newBody = makeEmptyBlock()
                return DeclSyntax(node.with(\.body, newBody))
            }

        default:
            if shouldElide(isPublic: pub) {
                let newBody = (policy == .signaturesOnly) ? makeSentinelBlock(from: body) : makeEmptyBlock()
                return DeclSyntax(node.with(\.body, newBody))
            }
            return DeclSyntax(super.visit(node))
        }
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> DeclSyntax {
        guard let body = node.body else { return DeclSyntax(super.visit(node)) }

        switch policy {
        case .keepOneBodyPerTypeElideRest:
            if shouldKeepOneHere(kindCountsAsExecutable: true) {
                return DeclSyntax(super.visit(node))
            } else {
                let newBody = makeEmptyBlock()
                return DeclSyntax(node.with(\.body, newBody))
            }

        default:
            if shouldElide(isPublic: false) {
                let newBody = (policy == .signaturesOnly) ? makeSentinelBlock(from: body) : makeEmptyBlock()
                return DeclSyntax(node.with(\.body, newBody))
            }
            return DeclSyntax(super.visit(node))
        }
    }

    // MARK: - Subscripts (accessor blocks)

    override func visit(_ node: SubscriptDeclSyntax) -> DeclSyntax {
        guard let ab = node.accessorBlock else { return DeclSyntax(super.visit(node)) }
        let pub = isPublicOrOpen(node.modifiers)

        switch policy {
        case .keepOneBodyPerTypeElideRest:
            if shouldKeepOneHere(kindCountsAsExecutable: true) {
                return DeclSyntax(super.visit(node))
            } else {
                // Elide accessors
                let replaced = node.with(\.accessorBlock, AccessorBlockSyntax(
                    leftBrace: .leftBraceToken(),
                    accessors: .accessors(AccessorDeclListSyntax([])),
                    rightBrace: .rightBraceToken()
                ))
                return DeclSyntax(replaced)
            }

        default:
            if shouldElide(isPublic: pub) {
                // Use sentinel only for signaturesOnly
                if policy == .signaturesOnly {
                    let statsText = ab.statementsTextForHash()
                    let lines = statsText.isEmpty ? 0 : statsText.split(separator: "\n").count
                    let comment = "/* elided-implemented; lines=\(lines); h=\(shortHash(statsText)) */"
                    let replaced = node.with(\.accessorBlock, AccessorBlockSyntax(
                        leftBrace: .leftBraceToken(trailingTrivia: .spaces(1) + .blockComment(comment) + .spaces(1)),
                        accessors: .accessors(AccessorDeclListSyntax([])),
                        rightBrace: .rightBraceToken()
                    ))
                    return DeclSyntax(replaced)
                } else {
                    let replaced = node.with(\.accessorBlock, AccessorBlockSyntax(
                        leftBrace: .leftBraceToken(),
                        accessors: .accessors(AccessorDeclListSyntax([])),
                        rightBrace: .rightBraceToken()
                    ))
                    return DeclSyntax(replaced)
                }
            }
            return DeclSyntax(super.visit(node))
        }
    }

    // MARK: - Computed properties (variable decls with accessor blocks)

    override func visit(_ node: VariableDeclSyntax) -> DeclSyntax {
        // In keepOneBodyPerTypeElideRest, DO NOT count computed properties as the kept body.
        // They are always elided under that policy.
        if policy == .keepOneBodyPerTypeElideRest {
            var newBindings = PatternBindingListSyntax([])
            for binding in node.bindings {
                if binding.accessorBlock != nil {
                    // Elide accessor bodies (empty block; canonicalized later if needed)
                    let newAB = AccessorBlockSyntax(
                        leftBrace: .leftBraceToken(),
                        accessors: .accessors(AccessorDeclListSyntax([])),
                        rightBrace: .rightBraceToken()
                    )
                    newBindings.append(binding.with(\.accessorBlock, newAB))
                } else {
                    newBindings.append(binding) // stored property — leave
                }
            }
            return DeclSyntax(node.with(\.bindings, newBindings))
        }

        // Other policies: follow public/non-public or sentinel rules
        let pub = isPublicOrOpen(node.modifiers)
        if shouldElide(isPublic: pub) {
            var newBindings = PatternBindingListSyntax([])
            for binding in node.bindings {
                if let ab = binding.accessorBlock {
                    if policy == .signaturesOnly {
                        let statsText = ab.statementsTextForHash()
                        let lines = statsText.isEmpty ? 0 : statsText.split(separator: "\n").count
                        let comment = "/* elided-implemented; lines=\(lines); h=\(shortHash(statsText)) */"
                        let newAB = AccessorBlockSyntax(
                            leftBrace: .leftBraceToken(trailingTrivia: .spaces(1) + .blockComment(comment) + .spaces(1)),
                            accessors: .accessors(AccessorDeclListSyntax([])),
                            rightBrace: .rightBraceToken()
                        )
                        newBindings.append(binding.with(\.accessorBlock, newAB))
                    } else {
                        let newAB = AccessorBlockSyntax(
                            leftBrace: .leftBraceToken(),
                            accessors: .accessors(AccessorDeclListSyntax([])),
                            rightBrace: .rightBraceToken()
                        )
                        newBindings.append(binding.with(\.accessorBlock, newAB))
                    }
                } else {
                    newBindings.append(binding)
                }
            }
            return DeclSyntax(node.with(\.bindings, newBindings))
        } else {
            return DeclSyntax(super.visit(node))
        }
    }
}

// MARK: - Small helpers

fileprivate extension AccessorBlockSyntax {
    /// Collect textual bodies of accessors to hash/line-count in a stable way.
    func statementsTextForHash() -> String {
        switch accessors {
        case .accessors(let list):
            return list.compactMap { acc -> String in
                if let b = acc.body { return b.statements.description } else { return "" }
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        case .getter:
            return "" // already abstract; nothing to hash
        @unknown default:
            return ""
        }
    }
}
