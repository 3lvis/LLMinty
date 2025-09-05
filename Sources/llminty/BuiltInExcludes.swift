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
