import Foundation

enum BuiltInExcludes {
    static func defaultPatterns(outputFileName: String) -> [String] {
        // Users can re-include via .mintyignore negation (!)
        return [
            // VCS / editor
            ".git/", ".gitignore", ".gitattributes", ".DS_Store", ".idea/", ".vscode/", ".svn/", ".hg/",
            // SwiftPM
            ".build/", ".swiftpm/",
            // Xcode
            "DerivedData/", "*.xcodeproj/", "*.xcworkspace/", "xcuserdata/",
            // Apple bundles/outputs
            "*.app/", "*.appex/", "*.framework/", "*.dSYM/", "*.xcarchive/",
            // Dependency managers
            "Pods/", "Carthage/",
            // Assets / binary noise (wide net by default)
            "*.xcassets/", "*.png", "*.jpg", "*.jpeg", "*.gif", "*.heic", "*.pdf",
            "*.svg", "*.webp", "*.ttf", "*.otf", "*.woff", "*.woff2",
            "*.zip", "*.tar", "*.tar.gz", "*.rar", "*.7z",
            "*.mp3", "*.wav", "*.aiff", "*.m4a", "*.mp4", "*.mov",
            "*.bin", "*.dat",
            // Self-exclude
            outputFileName
        ]
    }
}

/// Aggressively trims blank lines for final output while keeping exactly one
/// blank line after each "FILE: " header. Also:
/// - trims trailing spaces,
/// - collapses 3+ newlines to 2 during pre-pass,
/// - removes all other blank-only lines.
/// Returns a string that always ends with a single trailing newline.
func postProcessMinty(_ s: String) -> String {
    // 1) Trim trailing spaces and collapse extreme newline runs
    let pre = s
        .replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)

    // 2) Keep exactly one blank after each header; drop other blank-only lines
    let lines = pre.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    var result: [String] = []
    result.reserveCapacity(lines.count)
    var justSawHeader = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("FILE: ") {
            result.append(trimmed)       // store header without trailing spaces
            justSawHeader = true
            continue
        }
        if trimmed.isEmpty {
            if justSawHeader {
                result.append("")        // keep one blank after the header
            }
            // else: drop blank line
        } else {
            result.append(trimmed)       // keep non-blank (trimmed right/left)
            justSawHeader = false
        }
    }

    // 3) Single trailing newline
    let joined = result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return joined + "\n"
}

public struct LLMintyApp {
    public init() {}

    public func run() throws  {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)

        // Read .mintyignore if present
        let ignoreURL = root.appendingPathComponent(".mintyignore")
        let userIgnore = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""

        let matcher = try IgnoreMatcher(
            builtInPatterns: BuiltInExcludes.defaultPatterns(outputFileName: "minty.txt"),
            userFileText: userIgnore
        )

        // Scan
        let scanner = FileScanner(root: root, matcher: matcher)
        let files = try scanner.scan()

        // Analyze Swift files
        let analyzer = SwiftAnalyzer()
        let analyzedSwift = try analyzer.analyze(files: files)
        var analyzedByPath: [String: AnalyzedFile] = Dictionary(
            uniqueKeysWithValues: analyzedSwift.map { ($0.file.relativePath, $0) }
        )

        // Create stub analyzed entries for non-swift files (so we can score/order deterministically)
        for f in files where analyzedByPath[f.relativePath] == nil {
            let text: String
            switch f.kind {
            case .json, .text, .unknown:
                text = (try? String(contentsOf: f.absoluteURL, encoding: .utf8)) ?? ""
            case .binary:
                text = ""
            case .swift:
                text = "" // already analyzed above
            }
            analyzedByPath[f.relativePath] = AnalyzedFile(
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
        }

        // Score
        let allAnalyzed = files.compactMap { analyzedByPath[$0.relativePath] }
        let scorer = Scoring()
        let scored = scorer.score(analyzed: allAnalyzed)

        // Order (dependency-aware)
        let ordered = GraphCentrality.orderDependencyAware(scored)

        // Render
        let renderer = Renderer()
        var chunks: [String] = []
        chunks.reserveCapacity(ordered.count * 4)

        for s in ordered {
            let rendered = try renderer.render(file: s, score: s.score)
            chunks.append("FILE: \(rendered.relativePath)")
            chunks.append("") // exactly one blank after header (preserved by postProcess)
            chunks.append(rendered.content.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let raw = chunks.joined(separator: "\n") + "\n"
        let post = postProcessMinty(raw)

        // Write
        let outURL = root.appendingPathComponent("minty.txt")
        try post.write(to: outURL, atomically: true, encoding: .utf8)

        // Success message (exact)
        print("Created ./minty.txt (\(ordered.count) files)")
    }
}
