# LLMinty

Single-command CLI to emit a token-efficient bundle of a Swift repository for LLMs.

- **Command:** `llminty` (no args)
- **Output:** `./minty.txt`
- **Ignore file:** `.mintyignore` (gitignore semantics: globs, `!` negation, `/`-anchored, dir `/` suffix, `#` comments)
- **Deterministic:** Given the same repo & ignore, output is deterministic.

## Install

```bash
git clone <your fork>
cd LLMinty
swift build -c release
cp .build/release/llminty /usr/local/bin/
````

> If SwiftSyntax version mismatches your toolchain, pin `swift-syntax` to your local Swift’s compatible tag.

## Use

```bash
cd /path/to/your/swift/repo
llminty
# -> prints: Created ./minty.txt (<n> files)
```

```

---

### How this satisfies your spec (with your requested customizations)

- **CLI name:** `llminty` (binary); project name **LLMinty**.
- **Output file:** `minty.txt` (at repo root).
- **Ignore file:** `.mintyignore` (gitignore semantics, including `!` re‑include and dir patterns).
- **Built‑in safe excludes:** Implemented in `BuiltInExcludes.swift`, including self‑exclude of `minty.txt`; users can re‑include via negation.
- **High‑level flow:** Implemented end‑to‑end in `App.run()`.
- **Ranking (0–1):** Uses AST/graph‑only signals:
  - Fan‑in and PageRank centrality over file dependency graph (`GraphCentrality`).
  - Public API surface (public/open, protocols ×2).
  - Type/protocol influence (inbound refs to declared types).
  - Complexity via cyclomatic proxies (control‑flow nodes, boolean ops).
  - Entrypoint indicator (`@main`, SwiftUI `App`, or top‑level code).
- **Rendering (token‑minimized):**
  - **Swift:** Always preserves signatures, generics/where clauses, conformances, access modifiers, and imports. Bodies are retained or elided per score thresholds; very long bodies trimmed in place. One‑body‑per‑type enforced where applicable.
  - **JSON:** Keeps representative subset, head+tail arrays, with `// trimmed ...` notes; preserves order.
  - **Other text/binaries:** Condensed or replaced with compact placeholders with type/size.
- **Ordering:** Dependency‑aware topo order; tie‑break by higher score, then stable path.
- **Deterministic:** Stable scans, stable path sort, deterministic conflict resolution.
- **Performance:** Directory short‑circuiting; 2 MB per‑file cap; binary detection; no traversal outside CWD.
- **Security & Safety:** Never leaves working directory; unknown extensions treated as non‑text.
- **CLI UX:** On success prints **exactly**:
