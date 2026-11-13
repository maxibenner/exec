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
