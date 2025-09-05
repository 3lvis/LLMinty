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
        // Parse only Swift files; read text deterministically as UTF-8 (lossy ok)
        var analyzed: [AnalyzedFile] = []
        analyzed.reserveCapacity(files.count)

        for f in files where f.kind == .swift {
            let text = (try? String(contentsOf: f.absoluteURL, encoding: .utf8)) ?? ""
            let a = analyzeSwift(path: f.relativePath, text: text)
            analyzed.append(a)
        }

        // Map declared types -> file
        var typeToFile: [String: String] = [:]
        for a in analyzed {
            for t in a.declaredTypes { typeToFile[t, default: a.file.relativePath] = a.file.relativePath }
        }

        // Compute outgoing deps via referenced type → declared type mapping
        var pathToIndex: [String: Int] = [:]
        for (i, a) in analyzed.enumerated() { pathToIndex[a.file.relativePath] = i }

        for i in analyzed.indices {
            var deps = Set<String>()
            for (name, _) in analyzed[i].referencedTypes {
                if let depPath = typeToFile[name], depPath != analyzed[i].file.relativePath {
                    deps.insert(depPath)
                }
            }
            analyzed[i].outgoingFileDeps = Array(deps).sorted()
        }

        // Compute inbound counts
        var inbound: [String: Int] = [:]
        for a in analyzed {
            for dep in a.outgoingFileDeps {
                inbound[dep, default: 0] += 1
            }
        }
        for i in analyzed.indices {
            analyzed[i].inboundRefCount = inbound[analyzed[i].file.relativePath] ?? 0
        }

        return analyzed
    }

    private func analyzeSwift(path: String, text: String) -> AnalyzedFile {
        var ctx = CollectorContext()
        let tree = Parser.parse(source: text)
        let c = SwiftCollector(context: &ctx)
        c.walk(tree)

        // SwiftUI.App conformance implies entrypoint
        // Already captured in collector; pass through
        return AnalyzedFile(
            file: RepoFile(relativePath: path, absoluteURL: URL(fileURLWithPath: path), isDirectory: false, kind: .swift, size: UInt64(text.utf8.count)),
            text: text,
            declaredTypes: ctx.declaredTypes,
            publicAPIScoreRaw: ctx.publicAPIScoreRaw,
            referencedTypes: ctx.referencedTypes,
            complexity: ctx.complexity,
            isEntrypoint: ctx.isEntrypoint || ctx.hasTopLevelCode,
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

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind  {
        ctx.pointee.importedModules.insert(node.path.trimmedDescription)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind  {
        let name = node.name.text
        ctx.pointee.declaredTypes.insert(name)
        if node.modifiers.containsPublicOrOpen { ctx.pointee.publicAPIScoreRaw += 1 }
        // SwiftUI.App conformance?
        if node.inheritanceClauseContains(type: "App") { ctx.pointee.isEntrypoint = true }
        typeStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax)  { _ = typeStack.popLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind  {
        let name = node.name.text
        ctx.pointee.declaredTypes.insert(name)
        if node.modifiers.containsPublicOrOpen { ctx.pointee.publicAPIScoreRaw += 1 }
        typeStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax)  { _ = typeStack.popLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind  {
        let name = node.name.text
        ctx.pointee.declaredTypes.insert(name)
        if node.modifiers.containsPublicOrOpen { ctx.pointee.publicAPIScoreRaw += 1 }
        typeStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax)  { _ = typeStack.popLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind  {
        let name = node.name.text
        ctx.pointee.declaredTypes.insert(name)
        if node.modifiers.containsPublicOrOpen { ctx.pointee.publicAPIScoreRaw += 2 } // public protocol weight 2
        typeStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax)  { _ = typeStack.popLast() }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind  {
        if node.attributeName.trimmedDescription == "main" { ctx.pointee.isEntrypoint = true }
        return .visitChildren
    }

    override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind  {
        // If any top-level item is not a decl, consider there is top-level code
        for item in node.statements {
            if item.item.as(DeclSyntax.self) == nil {
                ctx.pointee.hasTopLevelCode = true
                break
            }
        }
        return .visitChildren
    }
    override func visitPost(_ node: SourceFileSyntax)  { /* no-op */ }

    // Types referenced (IdentifierTypeSyntax and MemberTypeSyntax roots)
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind  {
        let n = node.name.text
        if !n.isEmpty { ctx.pointee.referencedTypes[n, default: 0] += 1 }
        return .visitChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind  {
        let base = node.baseType.trimmedDescription
        if !base.isEmpty { ctx.pointee.referencedTypes[base, default: 0] += 1 }
        return .visitChildren
    }

    // Complexity: count control-flow keywords and boolean ops
    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind  {
        switch token.tokenKind {
        case .keyword(.if), .keyword(.for), .keyword(.while), .keyword(.guard),
                .keyword(.case), .keyword(.repeat), .keyword(.catch), .keyword(.switch):
            ctx.pointee.complexity += 1
        case .spacedBinaryOperator(let op):
            if op == "&&" || op == "||" { ctx.pointee.complexity += 1 }
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
    func inheritanceClauseContains(type: String) -> Bool  {
        if let clause = self.inheritanceClause {
            for it in clause.inheritedTypes {
                if it.type.trimmedDescription == type { return true }
            }
        }
        return false
    }
}
