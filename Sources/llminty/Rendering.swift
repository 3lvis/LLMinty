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
    enum RenderPolicy: Equatable {
        case keepAllBodiesLightlyCondensed
        case keepPublicBodiesElideOthers
        case keepOneBodyPerTypeElideRest
        case signaturesOnly
    }

    /// Map a 0–1 score to a rendering policy.
    func policyFor(score: Double) -> RenderPolicy {
        switch score {
        case let s where s >= 0.80: return .keepAllBodiesLightlyCondensed
        case let s where s >= 0.60: return .keepPublicBodiesElideOthers
        case let s where s >= 0.30: return .keepOneBodyPerTypeElideRest
        default:                    return .signaturesOnly
        }
    }

    /// Render a single file based on its kind and score.
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
                                content: Self.lightlyCondenseWhitespace(reduced))

        case .text, .unknown:
            // Line-aware compaction expected by tests
            return RenderedFile(relativePath: file.analyzed.file.relativePath,
                                content: Self.lightlyCondenseWhitespace(file.analyzed.text))

        case .binary:
            // Visible placeholder with size
            let bytes = file.analyzed.file.size
            let placeholder = "/* binary omitted; size=\(bytes) bytes */"
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: placeholder)
        }
    }

    // MARK: - Swift rendering

    /// Produces Swift text according to policy.
    func renderSwift(text: String, policy: RenderPolicy) throws -> String {
        let source = Parser.parse(source: text)
        let rewriter = ElideBodiesRewriter(policy: policy)
        let rewritten = rewriter.visit(source).description

        let canonicalized = (policy == .keepAllBodiesLightlyCondensed)
        ? rewritten
        : Self.canonicalizeEmptyBlocks(rewritten)

        return Self.lightlyCondenseWhitespace(canonicalized)
    }

    // MARK: - Pure helpers

    private static let emptyBlockRegex = try! NSRegularExpression(
        pattern: #"\{\s*\}"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Replace truly empty `{}` with `{ ... }` (rich sentinels are not empty).
    static func canonicalizeEmptyBlocks(_ text: String) -> String {
        emptyBlockRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "{ ... }"
        )
    }

    /// Normalize line endings, trim trailing spaces/tabs, collapse 3+ blank lines to 1.
    static func lightlyCondenseWhitespace(_ s: String) -> String {
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        var out: [String] = []
        out.reserveCapacity(rawLines.count)

        var prevBlank = false
        for raw in rawLines {
            var line = String(raw)
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }

            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank {
                if !prevBlank { out.append(""); prevBlank = true }
            } else {
                out.append(line); prevBlank = false
            }
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - SwiftSyntax rewriter

fileprivate final class ElideBodiesRewriter: SyntaxRewriter {
    private let policy: Renderer.RenderPolicy

    // Track current container (type or <toplevel>) for keep-one policy.
    private var typeStack: [String] = []
    private var keptOneByContainer = Set<String>()

    init(policy: Renderer.RenderPolicy) {
        self.policy = policy
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Sentinel + empty blocks

    /// `/* elided-implemented; lines=<N>; h=<short-hex> */`
    private func sentinelComment(lines: Int, hash: String) -> String {
        "/* elided-implemented; lines=\(lines); h=\(hash) */"
    }

    /// FNV-1a 64-bit; return first 10 hex chars.
    private func shortHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h &*= 0x100000001b3 }
        return String(h, radix: 16).prefix(10).lowercased()
    }

    private func sentinelBlock(from body: CodeBlockSyntax) -> CodeBlockSyntax {
        let text = body.statements.description.replacingOccurrences(of: "\r\n", with: "\n")
        let lineCount = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        let comment = sentinelComment(lines: lineCount, hash: shortHash(text))
        let lb = TokenSyntax.leftBraceToken(trailingTrivia: .spaces(1) + .blockComment(comment) + .spaces(1))
        return CodeBlockSyntax(leftBrace: lb, statements: CodeBlockItemListSyntax([]), rightBrace: .rightBraceToken())
    }

    private func emptyBlock() -> CodeBlockSyntax {
        CodeBlockSyntax(leftBrace: .leftBraceToken(), statements: CodeBlockItemListSyntax([]), rightBrace: .rightBraceToken())
    }

    private func replacedAccessorBlock(sentinelText: String?) -> AccessorBlockSyntax {
        let left = sentinelText == nil
        ? TokenSyntax.leftBraceToken()
        : TokenSyntax.leftBraceToken(trailingTrivia: .spaces(1) + .blockComment(sentinelText!) + .spaces(1))

        return AccessorBlockSyntax(
            leftBrace: left,
            accessors: .accessors(AccessorDeclListSyntax([])),
            rightBrace: .rightBraceToken()
        )
    }

    private func accessorSentinel(from ab: AccessorBlockSyntax) -> String {
        let stats = ab.statementsTextForHash()
        let lines = stats.isEmpty ? 0 : stats.split(separator: "\n").count
        return sentinelComment(lines: lines, hash: shortHash(stats))
    }

    private func containerKey() -> String { typeStack.last ?? "<toplevel>" }

    private func isPublicOrOpen(_ mods: DeclModifierListSyntax?) -> Bool {
        guard let mods else { return false }
        for m in mods {
            switch m.name.tokenKind {
            case .keyword(.public), .keyword(.open): return true
            default: continue
            }
        }
        return false
    }

    private func shouldElideNonPublic(_ isPublic: Bool) -> Bool {
        switch policy {
        case .keepAllBodiesLightlyCondensed: return false
        case .keepPublicBodiesElideOthers:   return !isPublic
        case .keepOneBodyPerTypeElideRest:   return false // handled per-decl below
        case .signaturesOnly:                return true
        }
    }

    private func shouldKeepOneHere(kindCountsAsExecutable: Bool) -> Bool {
        guard policy == .keepOneBodyPerTypeElideRest else { return true }
        let key = containerKey()
        if keptOneByContainer.contains(key) { return false }
        if kindCountsAsExecutable { keptOneByContainer.insert(key) }
        return kindCountsAsExecutable
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

    // MARK: - Executables

    override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
        guard let body = node.body else { return DeclSyntax(super.visit(node)) }
        let isPub = isPublicOrOpen(node.modifiers)

        switch policy {
        case .keepOneBodyPerTypeElideRest:
            if shouldKeepOneHere(kindCountsAsExecutable: true) {
                return DeclSyntax(super.visit(node))
            } else {
                return DeclSyntax(node.with(\.body, emptyBlock()))
            }
        case .signaturesOnly:
            return DeclSyntax(node.with(\.body, sentinelBlock(from: body)))
        default:
            if shouldElideNonPublic(isPub) { return DeclSyntax(node.with(\.body, emptyBlock())) }
            return DeclSyntax(super.visit(node))
        }
    }

    override func visit(_ node: InitializerDeclSyntax) -> DeclSyntax {
        guard let body = node.body else { return DeclSyntax(super.visit(node)) }

        switch policy {
        case .keepOneBodyPerTypeElideRest:
            if shouldKeepOneHere(kindCountsAsExecutable: true) {
                return DeclSyntax(super.visit(node))
            } else {
                return DeclSyntax(node.with(\.body, emptyBlock()))
            }
        case .signaturesOnly:
            return DeclSyntax(node.with(\.body, sentinelBlock(from: body)))
        default:
            if shouldElideNonPublic(isPublicOrOpen(node.modifiers)) {
                return DeclSyntax(node.with(\.body, emptyBlock()))
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
                return DeclSyntax(node.with(\.body, emptyBlock()))
            }
        case .signaturesOnly:
            return DeclSyntax(node.with(\.body, sentinelBlock(from: body)))
        default:
            if shouldElideNonPublic(false) { return DeclSyntax(node.with(\.body, emptyBlock())) }
            return DeclSyntax(super.visit(node))
        }
    }

    // MARK: - Subscripts (accessor blocks)

    override func visit(_ node: SubscriptDeclSyntax) -> DeclSyntax {
        guard let ab = node.accessorBlock else { return DeclSyntax(super.visit(node)) }

        switch policy {
        case .keepOneBodyPerTypeElideRest:
            if shouldKeepOneHere(kindCountsAsExecutable: true) { return DeclSyntax(super.visit(node)) }
            return DeclSyntax(node.with(\.accessorBlock, replacedAccessorBlock(sentinelText: nil)))

        case .signaturesOnly:
            let comment = accessorSentinel(from: ab)
            return DeclSyntax(node.with(\.accessorBlock, replacedAccessorBlock(sentinelText: comment)))

        default:
            if shouldElideNonPublic(isPublicOrOpen(node.modifiers)) {
                return DeclSyntax(node.with(\.accessorBlock, replacedAccessorBlock(sentinelText: nil)))
            }
            return DeclSyntax(super.visit(node))
        }
    }

    // MARK: - Computed properties

    override func visit(_ node: VariableDeclSyntax) -> DeclSyntax {
        // keep-one: computed properties are always elided and don't claim the slot
        if policy == .keepOneBodyPerTypeElideRest {
            var newBindings = PatternBindingListSyntax([])
            for b in node.bindings {
                if b.accessorBlock != nil {
                    let ab = replacedAccessorBlock(sentinelText: nil)
                    newBindings.append(b.with(\.accessorBlock, ab))
                } else {
                    newBindings.append(b)
                }
            }
            return DeclSyntax(node.with(\.bindings, newBindings))
        }

        // other policies: follow public/non-public or sentinel rules
        if shouldElideNonPublic(isPublicOrOpen(node.modifiers)) {
            var newBindings = PatternBindingListSyntax([])
            for b in node.bindings {
                if let ab = b.accessorBlock {
                    if policy == .signaturesOnly {
                        let comment = accessorSentinel(from: ab)
                        newBindings.append(b.with(\.accessorBlock, replacedAccessorBlock(sentinelText: comment)))
                    } else {
                        newBindings.append(b.with(\.accessorBlock, replacedAccessorBlock(sentinelText: nil)))
                    }
                } else {
                    newBindings.append(b)
                }
            }
            return DeclSyntax(node.with(\.bindings, newBindings))
        }

        return DeclSyntax(super.visit(node))
    }
}

// MARK: - Accessor hashing helper

fileprivate extension AccessorBlockSyntax {
    /// Collect textual bodies of accessors to hash/line-count deterministically.
    func statementsTextForHash() -> String {
        switch accessors {
        case .accessors(let list):
            return list
                .compactMap { $0.body?.statements.description ?? "" }
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
