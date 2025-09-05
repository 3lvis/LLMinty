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
            if justSawHeader { result.append("") } // keep one blank after the header
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
        let ignorePath = root.appendingPathComponent(".mintyignore").path

        // Read user ignore file (optional)
        let ignoreText = (try? String(contentsOfFile: ignorePath, encoding: .utf8)) ?? ""

        // Build matcher with built-ins first
        let matcher = try IgnoreMatcher(
            builtInPatterns: BuiltInExcludes.defaultPatterns(outputFileName: "minty.txt"),
            userFileText: ignoreText
        )

        // Scan
        let scanner = FileScanner(root: root, matcher: matcher)
        let files = try scanner.scan()

        // Analyze/score/order
        let analyzer = SwiftAnalyzer()
        let analyzed = try analyzer.analyze(files: files)
        let scorer = Scoring()
        let scored = scorer.score(analyzed: analyzed)
        let ordered = GraphCentrality.orderDependencyAware(scored)

        // Render
        let renderer = Renderer()
        var parts: [String] = []
        parts.reserveCapacity(ordered.count * 2)
        for s in ordered {
            let rf = try renderer.render(file: s, score: s.score)
            parts.append("FILE: \(rf.relativePath)")
            parts.append("")
            parts.append(rf.content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let joined = parts.joined(separator: "\n")
        let finalText = postProcessMinty(joined)

        // Write minty.txt
        let outURL = root.appendingPathComponent("minty.txt")
        try finalText.data(using: .utf8)?.write(to: outURL, options: [.atomic])

        // Success message (exact)
        print("Created ./minty.txt (\(ordered.count) files)")
    }
}
