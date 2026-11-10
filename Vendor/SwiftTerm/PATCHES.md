# Differences from upstream SwiftTerm v1.99.1 (2f573f73af5e768d90847dce20c97fa9535d7164)

No file copied from upstream is edited. UPSTREAM.sha256 lists every upstream file under Sources/SwiftTerm and LICENSE with its sha256
(its own digest is ff58b68e5605122c89bf054dcbe4320d3106d3562cecad7cd77ddf102de62b2a, 141 lines). scripts/check-vendor.py compares every file with it.

Left out of the copy: Sources/SwiftTerm/iOS/, Documentation.docc/, Mac/README.md, LocalProcess.swift, Pty.swift, HeadlessTerminal.swift,
Mac/MacLocalTerminalView.swift (no process spawning, no fork, no pty helpers).

Files added (each line: path, sha256, reason; scripts/check-vendor.py reads these lines):

- `Sources/SwiftTerm/SwiftTermBuildInfo.swift` sha256 `6810debaf6e4351ad232b2e732322ecb5613d747e55d46feee239ad68773d844` -- upstream's build plugin writes this constant enum; the plugin is not used, so it is written once for the pinned tag and commit.
- `Sources/SwiftTerm/SwiftTermTerminfo.swift` sha256 `76f1b840d8e32cf9d6b136e0d5486c12c3713aef38a1d6f00c84e0538fa0fe69` -- upstream's build plugin writes the XTGETTCAP table from swifterm-terminfo; it is empty here (as EmbeddedSupport.swift:117 has it), so XTGETTCAP queries get no capability answer.

Package.swift is Clawd's own: swift-tools 6.2, one library product and target, macOS 13, Swift 6 language mode, no dependencies, no traits, no plugin, and the exclude of Apple/Metal/Shaders.metal that upstream's target has.
