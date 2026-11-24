# Development

## Requirements

- Xcode 26+ with Swift and Icon Composer's asset compiler for macOS builds.
- Rust/Cargo 1.93+; if needed, run `source "$HOME/.cargo/env"`.
- `/bin/bash`; OpenSSL is also required for synthetic OIDC test fixtures.

The Rust backend targets Unix hosts (macOS/Linux). The Swift package targets macOS 14+. No Node installation is needed for the current applications.

## macOS

Open `macOS/Package.swift` in Xcode, or run from `macOS/`:

```sh
./scripts/test.sh
./scripts/build-app.sh
open dist/Exec.app
```

The test script builds this checkout's Rust helper, then compiles and runs the Swift checks. Both scripts use `macOS/.build/backend/` for Rust release artifacts; Swift artifacts stay under `macOS/.build/`. The distributable app is assembled in `macOS/dist/`. Do not commit build output.

The app bundles `Contents/MacOS/exec-agent`, built with the committed Cargo lockfile. It does not fall back to an installed helper. SwiftPM discovers nested source folders automatically; the test and transcript benchmark scripts likewise enumerate sources recursively.

`shared/ExecTranscript` is a static library with pinned Tree-sitter dependencies. Keep the generated application and shared-package `Package.resolved` files after resolving dependencies. Direct `swiftc` harnesses source `scripts/shared-transcript.sh` to build that product in `macOS/.build/` and use its module/link flags instead of compiling its sources directly. They copy `ExecTranscript_ExecTranscript.bundle` beside the executable; `build-app.sh` places it in `Contents/Resources` before signing. The bundle contains syntax queries and third-party license notices for the grammars, runtime and Swift wrapper.

Fenced code highlighting supports Swift, JavaScript/JSX, TypeScript/TSX, Python, Rust, Go, C/C++, Bash/shell, HTML, CSS, JSON and YAML. The fence language selects the grammar; unknown/unlabeled blocks stay plain. Tokenization runs on a shared actor with bounded parser state and a 2 MiB token cache. Native views coalesce changing code for 60 ms and discard superseded results. macOS applies display-only TextKit colors; UIKit changes foreground attributes without invalidating the code-block measurement cache. Neither path changes fonts or source text. Diffs and inline code retain their existing rendering.

Highlighting falls back to plain text above 128 KiB per block, on parser timeout or when token/query-work limits are exhausted. The query deadline is cooperative: the pinned SwiftTreeSitter wrapper cannot interrupt an individual native query traversal. These limits are work safeguards, not a frame-time guarantee. Focused tests cover language resources, incremental Unicode edits, cancellation/reuse, and storage/geometry preservation; actual scrolling and streaming smoothness still require interactive profiling.

App packaging resources live in `macOS/Resources/`: `Info.plist` and the layered `Glass_Icon.icon` document. `build-app.sh` compiles the icon and bundles/signs the helper and Sparkle framework. These are packaging resources outside the SwiftPM executable target, not copied source assets.

### Stable signing

Use an existing stable signing certificate so app/helper identity stays consistent across rebuilds:

```sh
security find-identity -v -p codesigning
git config --local exec.signingIdentity "<certificate SHA-1>"
REQUIRE_STABLE_SIGNING=1 ./scripts/build-app.sh
```

`SIGNING_IDENTITY` can explicitly override the configured identity. A signing failure must not silently select another certificate or relax Keychain access. Without a configured identity, the script warns and uses ad-hoc development signing unless `REQUIRE_STABLE_SIGNING=1` is set. Release signing/notarization is documented in [releasing.md](releasing.md).

The scripts keep `CARGO_PROFILE_RELEASE_STRIP=none`: some Rust/macOS combinations produce unloadable stripped proc-macro dylibs. Do not work around this by modifying or re-signing compiler artifacts.

### Parallel test builds

From `macOS/`, build the reusable development variant without replacing production:

```sh
./scripts/build-app.sh --dev
open "dist/Exec Dev.app"
```

`Exec Dev.app` has its own display/executable name, bundle ID `local.exec.dev`, preferences,
profile `~/Library/Application Support/Exec Dev/Agent`, and loopback port `8766`.
Its updater is disabled and the configured stable signing identity is preserved. Rebuilds
reuse only the dev profile; they never copy production state or credentials. Running the
script without `--dev` still produces the unchanged production variant, `Exec.app`.
Only one dev app can own the dev profile/port at a time; do not open another worktree's copy
while one is already running. The build does not start or stop either app automatically.

Sign in separately by default. An explicitly authorized static API key, such as DeepSeek's,
may be copied privately into the dev credential store without printing or committing it.
Never duplicate rotating OpenAI sign-in/refresh tokens across profiles: independent refresh
owners can invalidate each other's sessions. Never symlink the dev profile to production.

For additional custom variants, renaming alone is insufficient. Give the copied bundle a
distinct `CFBundleIdentifier`, `CFBundleName` and `CFBundleDisplayName`, plus these optional
Info.plist overrides:

- `ExecProfileName` (string): a single directory name. Data and provider credentials live under `Application Support/<name>/Agent`. The default remains `Exec`.
- `ExecAgentPort` (integer): an unused loopback port. The default remains `8765`.

Malformed overrides fail closed. Remove `SUFeedURL` from custom copies to disable their
updater; do not change the published production feed. Re-sign the copied helper and app
inside out with the configured stable certificate after modifying the bundle, verify the
signatures, and open that exact app path. Keep the test app outside a feature worktree before
removing the worktree. These settings isolate application state, not filesystem or desktop
access; use a disposable test workspace.

## Backend

From `backend/`:

```sh
cargo build --locked --release
cargo test --locked --all-targets
cargo test --locked --doc
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --check
```

Standalone startup uses a private profile and a separately provisioned API token:

```sh
export EXEC_AGENT_TOKEN="$(openssl rand -hex 32)"
./target/release/exec-agent --profile /absolute/private/profile --workspace-tools
```

Do not share an active app profile. File/shell tools are an explicit standalone opt-in. See [api.md](api.md) for deployment, provider credentials, native capabilities and conservative crash recovery.

## Source organization

Keep Rust runtime contracts in `core/`, provider details in `providers/`, and effectful actions in `tools/`. The native app groups UI by feature, shared rendering/windowing in `UI/`, native capture in `Platform/`, and helper integration in `Backend/`. See [architecture.md](architecture.md) for ownership and safety constraints.

Executable shell scripts belong in `macOS/scripts/`; standalone Swift diagnostic harnesses belong in `macOS/Tools/Benchmarks/`. Keep useful diagnostics reproducible without committing machine-specific reports. The [performance guide](performance.md) documents the supported entry points.

## Repository hygiene

Implement changes in a dedicated branch/worktree, verify them, use Conventional Commits, then merge and remove only that clean feature worktree. Preserve unrelated work. Run Git from this repository, not its parent.

Keep current documentation under `docs/` rather than retaining duplicate plans, audits and completed task logs. `README.md` is the entry point; `AGENTS.md` contains contributor/agent instructions. Git history retains removed reports and prototypes.

`docs/` also serves GitHub Pages. Keep `docs/appcast.xml`, `.nojekyll`, and published release-note URLs stable for installed clients. README images live in `docs/assets/`; the source app icon remains in `macOS/Resources/`. Published release notes are distribution records, not duplicate architecture documentation.

Before committing, run the relevant suites, rebuild macOS after app changes, and run `git diff --check`. Tests must use isolated stores and fake providers, never live account credentials or the user's Keychain. Report interactive checks that remain unverified rather than treating mocks as live-service validation.
