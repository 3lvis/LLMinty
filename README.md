# LLMinty

Single-command CLI that emits a **token-efficient bundle** of a Swift repository for LLMs.

* **Command:** `llminty` (no args)
* **Output:** `./minty.txt` at the repo root
* **Ignore file:** `.mintyignore` (gitignore-style: globs, `!` negation, root-anchored `/`, dir `/` suffix, `#` comments)
* **Deterministic:** Given the same repo + ignore rules, the output is deterministic.
* **Swift toolchain:** Swift **6.1** compatible (package pins `swift-syntax` **601.0.1**).

---

## Quick install (Homebrew)

We publish prebuilt macOS tarballs as GitHub release assets and provide a small Homebrew tap for easy installation.

One-time tap + install:

```bash
brew tap 3lvis/llminty
brew install llminty
```

One-liner (auto-taps if needed):

```bash
brew install 3lvis/llminty/llminty
```

Build-from-source (if you prefer):

```bash
git clone git@github.com:3lvis/LLMinty.git
cd LLMinty
swift build -c release
# copy to a bin dir (adjust for Intel/Apple Silicon system)
cp .build/*/release/llminty /usr/local/bin/   # or /opt/homebrew/bin/
```

Verify install:

```bash
which llminty
llminty --help
file "$(which llminty)"   # check architecture (arm64 vs x86_64)
```

> Note: Homebrew installs use the tarball you upload to GitHub Releases. To publish a new release, create a Git tag (e.g. `v0.1.1`) and push it — the release workflow will build and attach tarballs.

---

## Usage

Run from the **root of the Swift repo you want to condense**:

```bash
llminty
# → prints: "Created ./minty.txt (N files)"
```

This writes `minty.txt` with concatenated, minimally rendered source for the most important files first.

Output framing example:

```
FILE: Sources/MyModule/Foo.swift

struct Foo { ... }
```

Each file has a single blank line after the `FILE:` header and the final file ends with a trailing newline.

---

## What gets included (short)

LLMinty walks the repo, categorizes files, **ranks** them, and **renders** them to minimize tokens while preserving structure.

* **Ranking signals:** graph centrality (fan-in / PageRank), public API surface, type influence, complexity proxy, entrypoint indicators.
* **Rendering:** signatures preserved; low-value bodies elided to `{ ... }`; JSON reduced by head/tail sampling with `// trimmed …` annotations; text/unknown files included with caps; binaries skipped.
* **Size cap:** per-file cap (2 MB default).
* **Built-in excludes:** VCS/editor noise, `.build/`, derived Xcode artifacts, dependency folders, large assets, and `minty.txt` itself (self-exclude).

### `.mintyignore`

Use `.mintyignore` at repo root (gitignore syntax) to fine-tune inclusion. Example:

```gitignore
# Ignore tests and samples
Tests/
Examples/
**/*.png

# Keep golden snapshot sources
!Tests/**/Fixtures/**/*.swift
```

> Use `.mintyignore` (not `.llmintyignore`).

---

## Developing

```bash
swift build
swift test
```

Key sources:

* `App.swift`, `main.swift` – CLI wiring
* `FileScanner.swift`, `IgnoreMatcher.swift` – repo walk & ignore engine
* `SwiftAnalyzer.swift`, `Rendering.swift`, `Scoring.swift`, `GraphCentrality.swift`, `JSONReducer.swift` – analysis & rendering

---

## CI: auto-refresh `minty.txt`

You already added `.github/workflows/llminty.yml`. This workflow builds LLMinty on `macos-14`, runs it at the repo root, and auto-commits `minty.txt` when it changes.

Workflow summary:

* Trigger: `push` to `main` and `pull_request`
* Steps: checkout → `swift build -c release` → run `./.build/release/llminty` → commit `minty.txt` (if changed)

Alternative CI behavior:

* Upload `minty.txt` as a PR artifact instead of committing (use `actions/upload-artifact`).
* Limit commits to `push` on `main` using `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`.

---

## Release automation (build + upload binaries)

Use the `release.yml` workflow to create GitHub Release assets on tag push (e.g. `v0.1.0`). The release job builds LLMinty on the macOS runner and uploads a tarball named like:

```
llminty-v0.1.0-macos-arm64.tar.gz
```

If you want both `arm64` and `x86_64` artifacts automatically you can:

* add a self-hosted Intel macOS runner and run a separate job for x86\_64, or
* build one arch locally and upload the other to the same release (via `gh` or the API).

---

## Homebrew tap notes / troubleshooting

* Tap repo: `github.com/3lvis/homebrew-llminty` (formula `Formula/llminty.rb`). The formula expects a release tarball asset with the binary inside.
* If `brew audit` or `brew install` shows stale results, the local tapped clone may be out of sync. Refresh with:

```bash
# re-clone the tap used by Homebrew
brew untap 3lvis/llminty
brew tap 3lvis/llminty
```

* If Homebrew attempts to build from source and SPM uses manifest-time plugins, macOS sandboxing can cause `sandbox_apply: Operation not permitted`. To avoid that, the tap uses prebuilt tarballs so Homebrew installs the binary directly.

---

## FAQ

**Does LLMinty modify my repo?**
Only writes `minty.txt` at the root. Nothing else is changed.

**Should I commit `minty.txt`?**
Many teams do — useful for diffing and CI checks. Up to you.

**Will it run on CI?**
Yes — see the `.github/workflows/llminty.yml` you added.

---

## License

`MIT`
