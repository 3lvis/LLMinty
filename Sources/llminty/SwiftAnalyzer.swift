import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - Intermediate models

struct AnalyzedFile {
    let file: RepoFile
    let text: String
    // Declarations in this file (type names)
    var declaredTypes: Set<String>
    // Public/open API weighted counts (protocols ×2)
    var publicAPIScoreRaw: Int
    // Referenced type identifiers (simple heuristic)
    var referencedTypes: [String: Int] // name -> occurrences
    // Cyclomatic complexity sum across functions (very rough)
    var complexity: Int
    // Heuristic: does this target declare @main or SwiftUI.App or have top-level code?
    var isEntrypoint: Bool
    // Outgoing edges to other repo files by relative path (inferred via simple symbol map)
    var outgoingFileDeps: [String]
    // Inbound count (how many other files reference this one)
    var inboundRefCount: Int
}

// MARK: - Analyzer

final class SwiftAnalyzer {

    func analyze(files: [RepoFile]) throws -> [AnalyzedFile] {
        var analyzed: [AnalyzedFile] = []
        analyzed.reserveCapacity(files.count)

        for f in files {
            switch f.kind {
            case .swift:
                let text = try String(contentsOf: f.absoluteURL, encoding: .utf8)
                let base = analyzeSwift(path: f.relativePath, text: text)
                analyzed.append(base)
            case .json, .text, .unknown, .binary:
                // Non-swift placeholders filled later in rendering
                let text = (try? String(contentsOf: f.absoluteURL, encoding: .utf8)) ?? ""
                let base = AnalyzedFile(
                    file: f,
                    text: text,
                    declaredTypes: [],
                    publicAPIScoreRaw: 0,
                    referencedTypes: [:],
                    complexity: 0,
                    isEntrypoint: false,
                    outgoingFileDeps: [],
                    inboundRefCount: 0
                )
                analyzed.append(base)
            }
        }

        // Build symbol -> file map (first writer wins in stable path order)
        var symbolToFile: [String: String] = [:] // typeName -> relativePath
        for a in analyzed where a.file.kind == .swift {
            for t in a.declaredTypes.sorted() {
                if symbolToFile[t] == nil {
                    symbolToFile[t] = a.file.relativePath
                }
            }
        }

        // Project cross-file refs: naive map by referenced type names
        var inbound: [String: Int] = [:]
        for i in 0..<analyzed.count {
            var deps = Set<String>()
            for (ref, _) in analyzed[i].referencedTypes {
                if let defFile = symbolToFile[ref], defFile != analyzed[i].file.relativePath {
                    deps.insert(defFile)
                    inbound[defFile, default: 0] += 1
                }
            }
            analyzed[i].outgoingFileDeps = Array(deps).sorted()
        }
        for i in 0..<analyzed.count {
            analyzed[i].inboundRefCount = inbound[analyzed[i].file.relativePath, default: 0]
        }

        return analyzed
    }

    private func analyzeSwift(path: String, text: String) -> AnalyzedFile {
        let sf = Parser.parse(source: text)
        var ctx = CollectorContext()
        let collector = SwiftCollector(context: &ctx)
        collector.walk(sf)

        return AnalyzedFile(
            file: RepoFile(
                relativePath: path,
                absoluteURL: URL(fileURLWithPath: path), // not used later
                isDirectory: false,
                kind: .swift,
                size: UInt64(text.utf8.count)
            ),
            text: text,
            declaredTypes: ctx.declaredTypes,
            publicAPIScoreRaw: ctx.publicAPIScoreRaw,
            referencedTypes: ctx.referencedTypes,
            complexity: ctx.complexity,
            isEntrypoint: ctx.isEntrypoint,
            outgoingFileDeps: [],
            inboundRefCount: 0
        )
    }
}

// MARK: - Collector with SwiftSyntax

private struct CollectorContext {
    var declaredTypes: Set<String> = []
    var publicAPIScoreRaw: Int = 0
    var referencedTypes: [String: Int] = [:]
    var complexity: Int = 0
    var isEntrypoint: Bool = false
    var importedModules: Set<String> = []
    var hasTopLevelCode: Bool = false
}

private final class SwiftCollector: SyntaxVisitor {
    private var ctx: UnsafeMutablePointer<CollectorContext>
    private var typeStack: [String] = []

    init(context: inout CollectorContext) {
        self.ctx = withUnsafeMutablePointer(to: &context) { $0 }
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        ctx.pointee.importedModules.insert(node.path.trimmedDescription)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        ctx.pointee.declaredTypes.insert(name)
        if node.modifiers.containsPublicOrOpen { ctx.pointee.publicAPIScoreRaw += 1 }
        if node.inheritanceClauseContains(type: "App") && ctx.pointee.importedModules.contains("SwiftUI") {
            ctx.pointee.isEntrypoint = true
        }
        typeStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { _ = typeStack.popLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        ctx.pointee.declaredTypes.insert(name)
        if node.modifiers.containsPublicOrOpen { ctx.pointee.publicAPIScoreRaw += 1 }
        typeStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { _ = typeStack.popLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        ctx.pointee.declaredTypes.insert(name)
        if node.modifiers.containsPublicOrOpen { ctx.pointee.publicAPIScoreRaw += 1 }
        typeStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { _ = typeStack.popLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        ctx.pointee.declaredTypes.insert(name)
        // protocols ×2 if public/open
        if node.modifiers.containsPublicOrOpen { ctx.pointee.publicAPIScoreRaw += 2 }
        typeStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { _ = typeStack.popLast() }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        if node.attributeName.trimmedDescription == "main" {
            ctx.pointee.isEntrypoint = true
        }
        return .visitChildren
    }

    override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
        // Mark entrypoint if any top-level statement is not a declaration
        for item in node.statements {
            if !item.item.is(DeclSyntax.self) {
                ctx.pointee.hasTopLevelCode = true
                break
            }
        }
        return .visitChildren
    }

    override func visitPost(_ node: SourceFileSyntax) {
        if ctx.pointee.hasTopLevelCode { ctx.pointee.isEntrypoint = true }
    }

    // Types referenced (IdentifierTypeSyntax and MemberTypeSyntax roots)
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        let n = node.name.text
        if !n.isEmpty {
            ctx.pointee.referencedTypes[n, default: 0] += 1
        }
        return .visitChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        // Count the base name only (Foo.Bar -> Foo)
        let n = node.baseType.trimmedDescription
        if !n.isEmpty {
            ctx.pointee.referencedTypes[n, default: 0] += 1
        }
        return .visitChildren
    }

    // Complexity: count control-flow tokens and boolean ops
    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        switch token.text {
        case "if", "for", "while", "guard", "repeat", "switch":
            ctx.pointee.complexity += 1
        case "&&", "||":
            ctx.pointee.complexity += 1
        default:
            break
        }
        return .visitChildren
    }
}

// MARK: - Small helpers

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

private extension StructDeclSyntax {
    func inheritanceClauseContains(type: String) -> Bool {
        if let clause = self.inheritanceClause {
            for inhe in clause.inheritedTypes {
                if inhe.type.trimmedDescription == type { return true }
            }
        }
        return false
    }
}
