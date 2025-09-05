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
    private func compactText(_ s: String) -> String {
        var out: [String] = []
        out.reserveCapacity(max(1, s.count / 24))
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
    private func lightlyCondenseWhitespace(_ s: String) -> String {
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

    func policyFor(score: Double) -> SwiftPolicy {
        if score >= 0.75 { return .keepAllBodiesLightlyCondensed }
        if score >= 0.50 { return .keepPublicBodiesElideOthers }
        if score >= 0.25 { return .keepOneBodyPerTypeElideRest }
        return .signaturesOnly
    }

    // MARK: - Swift rendering (mechanical, deterministic elision)

    /// Mechanically elide Swift function/initializer bodies according to policy.
    /// Uses SwiftSyntax positions to replace bodies in the original source, so signatures remain intact.
    func renderSwift(text: String, policy: SwiftPolicy) throws -> String {
        if case .keepAllBodiesLightlyCondensed = policy {
            return lightlyCondenseWhitespace(text)
        }

        struct Replace {
            let startUTF8: Int // utf8 offset at '{'
            let endUTF8: Int   // utf8 offset *after* '}'
        }

        final class Planner: SyntaxVisitor {
            let policy: SwiftPolicy
            var replaces: [Replace] = []

            // type stack for one-per-type policy
            private var typeStack: [String] = []
            private var keptByType: Set<String> = []

            init(policy: SwiftPolicy) {
                self.policy = policy
                super.init(viewMode: .sourceAccurate)
            }

            private func currentTypeKey() -> String {
                return typeStack.isEmpty ? "<top>" : typeStack.joined(separator: ".")
            }

            private func isPublic(_ mods: DeclModifierListSyntax?) -> Bool {
                guard let mods = mods else { return false }
                for m in mods {
                    let k = m.name.text
                    if k == "public" || k == "open" { return true }
                }
                return false
            }

            private func shouldElide(isPublic: Bool) -> Bool {
                switch policy {
                case .signaturesOnly:
                    return true
                case .keepPublicBodiesElideOthers:
                    return !isPublic
                case .keepOneBodyPerTypeElideRest:
                    let key = currentTypeKey()
                    if keptByType.contains(key) { return true }
                    keptByType.insert(key)
                    return false
                case .keepAllBodiesLightlyCondensed:
                    return false
                }
            }

            // Track types
            override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
                typeStack.append(node.name.text)
                return .visitChildren
            }
            override func visitPost(_ node: StructDeclSyntax) { _ = typeStack.popLast() }

            override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
                typeStack.append(node.name.text)
                return .visitChildren
            }
            override func visitPost(_ node: ClassDeclSyntax) { _ = typeStack.popLast() }

            override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
                typeStack.append(node.name.text)
                return .visitChildren
            }
            override func visitPost(_ node: EnumDeclSyntax) { _ = typeStack.popLast() }

            // Functions
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                guard let body = node.body else { return .skipChildren }
                let pub = isPublic(node.modifiers)
                if shouldElide(isPublic: pub) {
                    let start = body.leftBrace.position.utf8Offset
                    let end = body.rightBrace.endPosition.utf8Offset
                    replaces.append(Replace(startUTF8: start, endUTF8: end))
                }
                return .skipChildren
            }

            // Inits
            override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
                guard let body = node.body else { return .skipChildren }
                let pub = isPublic(node.modifiers)
                if shouldElide(isPublic: pub) {
                    let start = body.leftBrace.position.utf8Offset
                    let end = body.rightBrace.endPosition.utf8Offset
                    replaces.append(Replace(startUTF8: start, endUTF8: end))
                }
                return .skipChildren
            }
        }

        let tree = Parser.parse(source: text)
        let planner = Planner(policy: policy)
        planner.walk(tree)

        guard !planner.replaces.isEmpty else {
            return lightlyCondenseWhitespace(text)
        }

        // Replace from the end to keep offsets stable; map utf8 offsets via the utf8 view.
        var result = text
        let sorted = planner.replaces.sorted { $0.startUTF8 > $1.startUTF8 }

        for r in sorted {
            let u8 = result.utf8
            guard
                let startU8 = u8.index(u8.startIndex, offsetBy: r.startUTF8, limitedBy: u8.endIndex),
                let endU8   = u8.index(u8.startIndex, offsetBy: r.endUTF8,   limitedBy: u8.endIndex),
                let startIdx = String.Index(startU8, within: result),
                let endIdx   = String.Index(endU8,   within: result)
            else { continue }
            result.replaceSubrange(startIdx..<endIdx, with: " {...}")
        }

        return lightlyCondenseWhitespace(result)
    }
}

extension StringProtocol {
    var isNewline: Bool { return self == "\n" || self == "\r\n" }
}
