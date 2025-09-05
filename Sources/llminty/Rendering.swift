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

    // MARK: - Text compaction

    /// For .text / .unknown: trim trailing spaces per line, collapse runs of blank lines to a single blank.
    private func compactText(_ s: String) -> String  {
        var out: [String] = []
        out.reserveCapacity(s.count / 24)
        var lastBlank = false
        for raw in s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = String(raw)
            while line.last == " " || line.last == "\t" { _ = line.removeLast() }
            let isBlank = line.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty
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

    /// For Swift bodies: a gentle pass that trims trailing spaces and collapses 3+ blank lines to 2.
    private func lightlyCondenseWhitespace(_ s: String) -> String  {
        let trimmedRight = s.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression, range: nil)
        return trimmedRight.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression, range: nil)
    }

    // MARK: - Swift policies

    enum SwiftPolicy {
        case keepAllBodiesLightlyCondensed            // s ≥ 0.75
        case keepPublicBodiesElideOthers              // 0.50 ≤ s < 0.75
        case keepOneBodyPerTypeElideRest              // 0.25 ≤ s < 0.50
        case signaturesOnly                           // s < 0.25
    }

    func policyFor(score: Double) -> SwiftPolicy  {
        if score >= 0.75 { return .keepAllBodiesLightlyCondensed }
        if score >= 0.50 { return .keepPublicBodiesElideOthers }
        if score >= 0.25 { return .keepOneBodyPerTypeElideRest }
        return .signaturesOnly
    }

    // MARK: - Swift rendering (mechanical, deterministic elision)

    /// Mechanically elide Swift function/initializer/subscript bodies according to policy.
    /// Uses SwiftSyntax rewriting to preserve signatures verbatim.
    func renderSwift(text: String, policy: SwiftPolicy) throws -> String  {
        if policy == .keepAllBodiesLightlyCondensed {
            return lightlyCondenseWhitespace(text)
        }

        final class Elider: SyntaxRewriter {
            let policy: Renderer.SwiftPolicy
            var typeStack: [String] = []
            var kept: Set<String> = [] // one kept body per fully-qualified type

            init(policy: Renderer.SwiftPolicy) {
                self.policy = policy
                super.init(viewMode: .sourceAccurate)
            }

            private func fqType() -> String? {
                guard !typeStack.isEmpty else { return nil }
                return typeStack.joined(separator: ".")
            }

            private func shouldKeepBody(isPublic: Bool) -> Bool {
                switch policy {
                case .signaturesOnly:
                    return false
                case .keepOneBodyPerTypeElideRest:
                    guard let fq = fqType() else { return false }
                    if kept.contains(fq) { return false }
                    kept.insert(fq)
                    return true
                case .keepPublicBodiesElideOthers:
                    return isPublic
                case .keepAllBodiesLightlyCondensed:
                    return true
                }
            }

            private func emptyBlock() -> CodeBlockSyntax {
                CodeBlockSyntax(
                    leftBrace: .leftBraceToken(leadingTrivia: .space, trailingTrivia: .space),
                    statements: CodeBlockItemListSyntax([]),
                    rightBrace: .rightBraceToken(trailingTrivia: .newline)
                )
            }

            // Type entries
            override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
                typeStack.append(node.name.text)
                let visited = super.visit(node)
                _ = typeStack.popLast()
                return visited
            }
            override func visit(_ node: ClassDeclSyntax) -> DeclSyntax {
                typeStack.append(node.name.text)
                let visited = super.visit(node)
                _ = typeStack.popLast()
                return visited
            }
            override func visit(_ node: EnumDeclSyntax) -> DeclSyntax {
                typeStack.append(node.name.text)
                let visited = super.visit(node)
                _ = typeStack.popLast()
                return visited
            }
            override func visit(_ node: ProtocolDeclSyntax) -> DeclSyntax {
                typeStack.append(node.name.text)
                let visited = super.visit(node)
                _ = typeStack.popLast()
                return visited
            }

            // Functions
            override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
                guard node.body != nil else { return DeclSyntax(node) }
                let isPublic = node.modifiers.containsPublicOrOpen
                if shouldKeepBody(isPublic: isPublic) { return DeclSyntax(node) }
                let replaced = node.with(\.body, emptyBlock())
                return DeclSyntax(replaced)
            }

            // Inits
            override func visit(_ node: InitializerDeclSyntax) -> DeclSyntax {
                guard node.body != nil else { return DeclSyntax(node) }
                let isPublic = node.modifiers.containsPublicOrOpen
                if shouldKeepBody(isPublic: isPublic) { return DeclSyntax(node) }
                let replaced = node.with(\.body, emptyBlock())
                return DeclSyntax(replaced)
            }

            // Subscripts (replace accessor block with empty accessor list)
            override func visit(_ node: SubscriptDeclSyntax) -> DeclSyntax {
                if node.accessorBlock != nil {
                    let isPublic = node.modifiers.containsPublicOrOpen
                    if shouldKeepBody(isPublic: isPublic) { return DeclSyntax(node) }
                    let emptyList = AccessorDeclListSyntax([])
                    let empty = AccessorBlockSyntax(accessors: .accessors(emptyList))
                    let replaced = node.with(\.accessorBlock, empty)
                    return DeclSyntax(replaced)
                }
                return DeclSyntax(node)
            }
        }

        let tree = Parser.parse(source: text)
        let rewriter = Elider(policy: policy)
        let out = rewriter.visit(tree)
        return lightlyCondenseWhitespace(out.description)
    }
}

extension StringProtocol {
    var isNewline: Bool { self == "\n" || self == "\r\n" }
}
