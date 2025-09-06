// Sources/llminty/Rendering.swift
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
            return RenderedFile(
                relativePath: file.analyzed.file.relativePath,
                content: compactText(file.analyzed.text)
            )
        case .binary:
            let size = file.analyzed.file.size
            let type = (file.analyzed.file.relativePath as NSString).pathExtension.lowercased()
            let placeholder = "/* binary \(type.isEmpty ? "file" : type) — \(size) bytes (omitted) */\n"
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: placeholder)
        }
    }

    // MARK: - Text passes

    private func compactText(_ s: String) -> String {
        var out: [String] = []
        out.reserveCapacity(max(1, s.count / 24))
        var lastBlank = false
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
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

    private func lightlyCondenseWhitespace(_ s: String) -> String {
        var out: [String] = []
        out.reserveCapacity(max(1, s.count / 24))
        var blankCount = 0
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            while line.last == " " || line.last == "\t" { _ = line.removeLast() }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankCount += 1
                if blankCount <= 2 { out.append("") }
            } else {
                blankCount = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Policy

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

    // MARK: - Swift elision

    func renderSwift(text: String, policy: SwiftPolicy) throws -> String {
        let source = Parser.parse(source: text)

        if policy == .keepAllBodiesLightlyCondensed {
            return lightlyCondenseWhitespace(text)
        }

        final class Rewriter: SyntaxRewriter {
            let policy: SwiftPolicy
            private var typeStack: [String] = []
            private var keptBodyForType: Set<String> = []

            init(policy: SwiftPolicy) { self.policy = policy }

            private func isPublicOrOpen(_ mods: DeclModifierListSyntax?) -> Bool {
                guard let mods else { return false }
                for m in mods {
                    let k = m.name.text
                    if k == "public" || k == "open" { return true }
                }
                return false
            }

            private func shouldElide(isPublic: Bool) -> Bool {
                switch policy {
                case .signaturesOnly: return true
                case .keepPublicBodiesElideOthers: return !isPublic
                case .keepOneBodyPerTypeElideRest:
                    let current = typeStack.joined(separator: ".")
                    if keptBodyForType.contains(current) { return true }
                    keptBodyForType.insert(current)
                    return false
                case .keepAllBodiesLightlyCondensed:
                    return false
                }
            }

            // Types
            override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
                typeStack.append(node.name.text)
                let rewritten = super.visit(node)
                _ = typeStack.popLast()
                return DeclSyntax(rewritten.as(StructDeclSyntax.self) ?? node)
            }
            override func visit(_ node: ClassDeclSyntax) -> DeclSyntax {
                typeStack.append(node.name.text)
                let rewritten = super.visit(node)
                _ = typeStack.popLast()
                return DeclSyntax(rewritten.as(ClassDeclSyntax.self) ?? node)
            }
            override func visit(_ node: EnumDeclSyntax) -> DeclSyntax {
                typeStack.append(node.name.text)
                let rewritten = super.visit(node)
                _ = typeStack.popLast()
                return DeclSyntax(rewritten.as(EnumDeclSyntax.self) ?? node)
            }
            override func visit(_ node: ProtocolDeclSyntax) -> DeclSyntax {
                typeStack.append(node.name.text)
                let rewritten = super.visit(node)
                _ = typeStack.popLast()
                return DeclSyntax(rewritten.as(ProtocolDeclSyntax.self) ?? node)
            }

            // Bodies
            override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
                guard node.body != nil else { return DeclSyntax(node) }
                if shouldElide(isPublic: isPublicOrOpen(node.modifiers)) {
                    let replaced = node.with(\.body, emptyBlock())
                    return DeclSyntax(replaced)
                }
                return DeclSyntax(node)
            }

            override func visit(_ node: InitializerDeclSyntax) -> DeclSyntax {
                guard node.body != nil else { return DeclSyntax(node) }
                if shouldElide(isPublic: isPublicOrOpen(node.modifiers)) {
                    let replaced = node.with(\.body, emptyBlock())
                    return DeclSyntax(replaced)
                }
                return DeclSyntax(node)
            }

            override func visit(_ node: SubscriptDeclSyntax) -> DeclSyntax {
                guard let _ = node.accessorBlock else { return DeclSyntax(node) }
                if shouldElide(isPublic: isPublicOrOpen(node.modifiers)) {
                    // {}
                    let empty = AccessorBlockSyntax(
                        leftBrace: .leftBraceToken(),
                        accessors: .accessors(AccessorDeclListSyntax([])),
                        rightBrace: .rightBraceToken()
                    )
                    let replaced = node.with(\.accessorBlock, empty)
                    return DeclSyntax(replaced)
                }
                let rewritten = super.visit(node)
                return DeclSyntax(rewritten.as(SubscriptDeclSyntax.self) ?? node)
            }

            private func emptyBlock() -> CodeBlockSyntax {
                CodeBlockSyntax(
                    leftBrace: .leftBraceToken(),
                    statements: CodeBlockItemListSyntax([]),
                    rightBrace: .rightBraceToken()
                )
            }
        }

        let rw = Rewriter(policy: policy)
        let rewritten = rw.visit(source)
        var result = rewritten.description

        // Canonicalize empty blocks to "{ ... }" for stable elision markers.
        if policy != .keepAllBodiesLightlyCondensed {
            let regex = try! NSRegularExpression(pattern: #"\{\s*\}"#, options: [])
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "{ ... }"
            )
        }
        return lightlyCondenseWhitespace(result)
    }
}
