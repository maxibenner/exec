<p align="center">
  <img src="docs/exec-icon-v0.1.6.png" alt="Exec app icon" width="80" height="80">
</p>

# Exec

A minimal, native macOS coding agent. Starts up lightning fast and offers hotkeys for quick navigation and config changes.

Currently supports OpenAI via subscription and DeepSeek via API key.

[Download for MacOS](https://github.com/maxibenner/exec/releases/latest/download/Exec-macOS-arm64.dmg)

# Philosophy

Exec is not meant to be the everything-app. It is purposefully kept minimal to slot into existing workflows. E.g. Exec does not contain a voice dictation mode, but it can easily be used with tools like [Handy](https://handy.computer). It also does not include a native file viewer, but it does include / commands to open the current workspace in either the Finder or Terminal to easily check e.g. `git status` there.


## Get started

To build from source, use Xcode 26 or later (including the Swift toolchain and Icon Composer asset compiler) and Rust/Cargo 1.93 or later. The build bundles the Rust backend; installed apps launch it automatically and do not require Cargo.

```sh
cd macOS
./scripts/build-app.sh
```

## Backend integration

The existing native UI and virtualized transcript renderer use one bundled Rust HTTP API, authenticated on **`127.0.0.1:8765` by default**. Swift provisions ephemeral API and native-capture credentials for its helper. Provider authentication, inference, tools, approvals, persistence and recovery belong to Rust, not a second Swift runner. The backend executable has no CLI client.

Standalone backend network binding is explicit (`--host IP --port PORT`, or `EXEC_AGENT_HOST` / `EXEC_AGENT_PORT`). Other trusted frontends can use that backend with `Authorization: Bearer <EXEC_AGENT_TOKEN>`; use HTTPS termination or an encrypted tunnel for remote access. The current Swift app always launches its own bundled helper at `127.0.0.1:8765` and cannot select an external backend. It ignores standalone endpoint and credential environment settings and generates fresh private helper credentials. See [HTTP deployment and client configuration](docs/http-api-review.md) for setup, capability boundaries and verification limits.

The app uses a fresh profile at `~/Library/Application Support/Exec/Agent/`. Credentials are stored in a private plaintext file. No old Swift conversations or Keychain entries are imported or removed; reconnect providers in Settings.

See [the migration report](docs/swift-rust-migration.md) for the exact compatibility adjustments, unsupported flows and verification boundaries. Automatic session titles are enabled by default in Settings and owned by the backend; manual names are never overwritten. Screenshots use an explicit per-conversation `/screenshots` grant; model/reasoning/auto-mode changes and compaction/fork commands can be queued mid-turn. `/workspace` permits one initial choice, including in a new conversation with an inherited folder, then becomes inactive. Account allowance refreshes when Settings opens. Compaction activity rows remain deferred.


## Keyboard controls

| Action                          | Shortcut            |
| ------------------------------- | ------------------- |
| New conversation                | ⌘T                  |
| Switch conversations            | ⌘1 - ⌘9             |
| Detach conversation             | ⌘D                  |
| Move detached conversation back | ⌘W                  |
| Delete conversation             | ⌘⇧Delete            |
| Previous sent message           | ⌘↑                  |
| Next sent message               | ⌘↓                  |
| Interrupt turn                  | Escape              |

Slash commands: `/model`, `/reasoning`, `/auto-approve`, `/compact`, `/fork`, `/workspace`, `/finder`, `/terminal`.

![Exec screenshot](screenshot-2.png)

## Development

Open `macOS/Package.swift` in Xcode, or run from `macOS/`:

```sh
./scripts/test.sh
./scripts/build-app.sh
```

Tests use isolated profiles, fake transports and a local Rust subprocess, not your Keychain or live model calls.

For consistent app/helper identity across rebuilds, configure a stable signing certificate:

```sh
security find-identity -v -p codesigning
git config --local exec.signingIdentity "<certificate SHA-1>"
REQUIRE_STABLE_SIGNING=1 ./scripts/build-app.sh
```
