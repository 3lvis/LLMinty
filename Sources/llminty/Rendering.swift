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
            let placeholder = "/* binary \(type.isEmpty ? "file" : type) — \(size) bytes (omitted) */"
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: placeholder)
        }
    }

    // MARK: - Text compaction

    /// Trim trailing spaces per line; collapse runs of blank lines to a single blank line.
    private func compactText(_ s: String) -> String {
        var out: [String] = []
        out.reserveCapacity(s.count / 24)
        var lastBlank = false
        for raw in s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = String(raw)
            while line.last == " " || line.last == "\t" { _ = line.removeLast() }
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank {
                if !lastBlank { out.append("") }
                lastBlank = true
            } else {
                out.append(line)
                lastBlank = false
            }
        }
        return out.joined(separator: "\n")
    }

    /// For kept Swift bodies under high score: gentler than `compactText`.
    /// - trims trailing spaces
    /// - collapses 3+ blank lines to 2
    private func lightlyCondenseWhitespace(_ s: String) -> String {
        let trimmed = s.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        return trimmed.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    // MARK: - Swift policies

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

    // MARK: - Swift rendering (mechanical elision)

    /// Replace function/init bodies (and subscript accessor blocks) per policy.
    /// Bodies elided are emitted as `{ ...}` exactly (we insert a comment marker during rewriting and normalize to ` ...` afterwards).
    func renderSwift(text: String, policy: SwiftPolicy) throws -> String {
        if policy == .keepAllBodiesLightlyCondensed {
            return lightlyCondenseWhitespace(text)
        }

        let tree = Parser.parse(source: text)

        final class ElidingRewriter: SyntaxRewriter {
            let policy: Renderer.SwiftPolicy
            var typeStack: [String] = []
            var keptOneForType = Set<String>()

            init(policy: Renderer.SwiftPolicy) {
                self.policy = policy
                super.init(viewMode: .sourceAccurate)
            }

            // Helper: determine access control
            private func isPublicOrOpen(_ mods: DeclModifierListSyntax?) -> Bool {
                guard let mods else { return false }
                for m in mods {
                    let k = m.name.text
                    if k == "public" || k == "open" { return true }
                }
                return false
            }

            // Marker block: prints as `{ /*__ELIDED__*/ }`
            private func elidedCodeBlock() -> CodeBlockSyntax {
                let left = TokenSyntax.leftBraceToken(
                    trailingTrivia: [.spaces(1), .blockComment("/*__ELIDED__*/"), .spaces(1)]
                )
                return CodeBlockSyntax(
                    leftBrace: left,
                    statements: CodeBlockItemListSyntax([]),
                    rightBrace: .rightBraceToken()
                )
            }

            // Marker accessor block: prints as `{ /*__ELIDED__*/ }`
            private func elidedAccessorBlock() -> AccessorBlockSyntax {
                let left = TokenSyntax.leftBraceToken(
                    trailingTrivia: [.spaces(1), .blockComment("/*__ELIDED__*/"), .spaces(1)]
                )
                return AccessorBlockSyntax(
                    leftBrace: left,
                    accessors: .accessors(AccessorDeclListSyntax([])),
                    rightBrace: .rightBraceToken()
                )
            }

            private func shouldElide(isPublic: Bool) -> Bool {
                switch policy {
                case .signaturesOnly:
                    return true
                case .keepPublicBodiesElideOthers:
                    return !isPublic
                case .keepOneBodyPerTypeElideRest:
                    if isPublic { return false }
                    let key = typeStack.joined(separator: ".")
                    if keptOneForType.contains(key) { return true }
                    keptOneForType.insert(key)
                    return false
                case .keepAllBodiesLightlyCondensed:
                    return false
                }
            }

            // Type nesting
            override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
                typeStack.append(node.name.text)
                let rewritten: DeclSyntax = super.visit(node)
                _ = typeStack.popLast()
                return rewritten
            }

            override func visit(_ node: ClassDeclSyntax) -> DeclSyntax {
                typeStack.append(node.name.text)
                let rewritten: DeclSyntax = super.visit(node)
                _ = typeStack.popLast()
                return rewritten
            }

            override func visit(_ node: EnumDeclSyntax) -> DeclSyntax {
                typeStack.append(node.name.text)
                let rewritten: DeclSyntax = super.visit(node)
                _ = typeStack.popLast()
                return rewritten
            }

            override func visit(_ node: ProtocolDeclSyntax) -> DeclSyntax {
                typeStack.append(node.name.text)
                let rewritten: DeclSyntax = super.visit(node)
                _ = typeStack.popLast()
                return rewritten
            }

            // Bodies
            override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
                guard node.body != nil else { return DeclSyntax(node) }
                let isPub = isPublicOrOpen(node.modifiers)
                if shouldElide(isPublic: isPub) {
                    let replaced = node.with(\.body, elidedCodeBlock())
                    return DeclSyntax(replaced)
                }
                return DeclSyntax(node)
            }

            override func visit(_ node: InitializerDeclSyntax) -> DeclSyntax {
                guard node.body != nil else { return DeclSyntax(node) }
                let isPub = isPublicOrOpen(node.modifiers)
                if shouldElide(isPublic: isPub) {
                    let replaced = node.with(\.body, elidedCodeBlock())
                    return DeclSyntax(replaced)
                }
                return DeclSyntax(node)
            }

            override func visit(_ node: SubscriptDeclSyntax) -> DeclSyntax {
                guard node.accessorBlock != nil else { return DeclSyntax(node) }
                let isPub = isPublicOrOpen(node.modifiers)
                if shouldElide(isPublic: isPub) {
                    let replaced = node.with(\.accessorBlock, elidedAccessorBlock())
                    return DeclSyntax(replaced)
                }
                let rewritten: DeclSyntax = super.visit(node)
                return rewritten
            }
        }

        let rewriter = ElidingRewriter(policy: policy)
        let rewritten = rewriter.visit(tree)
        var out = rewritten.description

        // Normalize our marker to the literal ellipsis the tests expect
        out = out.replacingOccurrences(of: "{ /*__ELIDED__*/ }", with: "{ ...}")

        // Gentle whitespace pass to keep output compact but readable
        return lightlyCondenseWhitespace(out)
    }
}
