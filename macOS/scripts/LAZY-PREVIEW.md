# Interactive lazy-transcript preview

From `macOS/`, run:

```sh
bash scripts/build-lazy-preview.sh
# Or choose a different, nonexistent destination:
bash scripts/build-lazy-preview.sh "$HOME/Desktop/Exec Lazy Preview 2.app"
```

This generates a temporary source copy under `.build/`, substitutes an experimental
SwiftUI `ScrollView` / `LazyVStack` container, and builds it with the normal
`./scripts/build-app.sh` and configured signing identity. It copies the signed app
to the Desktop (or supplied destination), refusing to overwrite an existing app.
The temporary source/build tree is removed afterward. Production sources and the
normal `dist/Exec.app` are unchanged.

The preview has a separate bundle ID (`local.swift-harness.lazy-preview`),
preferences, Keychain service, account cache, and conversation directory:
`~/Library/Application Support/Exec Lazy Preview/Exec/`. It does not copy your
normal conversation history or credentials. Automatic and manual app updates are
disabled in the preview.

On first launch it installs two synthetic conversations (400 and 2,000 messages).
Choose either one in the sidebar to test scrolling, selection and window/sidebar
resizing without signing in or making model calls. Existing preview data is
preserved on later launches. Signing in or sending messages is optional and uses
the preview's separate account/store; it is not required for these fixtures.

Limitations: this is an interactive prototype, not a complete transcript rewrite.
Sent-message navigation shortcuts are disabled, sessions open at the bottom rather
than restoring their reading anchor, and streaming/expansion/selection behavior is
not fully regression-verified. The lazy container requires macOS 15+; older systems
use the existing virtual transcript. Its extra geometry tracking for interactive
bottom-following means it is not byte-for-byte the smaller benchmark container.
No sidebar/header material changes are included.

Verification for the initial Desktop build: 237 existing production checks passed;
the generated preview compiled, was signed with the configured stable identity,
and passed `codesign --verify --deep --strict`. A launch check confirmed the isolated
synthetic conversations appeared in the sidebar. Live provider calls and manual
scrolling/selection interactions were not verified.
