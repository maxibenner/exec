<p align="center">
  <img src="macOS/Resources/Glass_Icon.png" alt="Exec glass app icon" width="64" height="64">
</p>

# Exec

A minimal, native macOS coding agent. Starts up lightning fast and offers hotkeys for quick navigation and config changes.

Currently supports OpenAI via subscription and DeepSeek via API key.

# Philosophy

Exec is not meant to be the everything-app. It is purposefully kept minimal to slot into existing workflows. E.g. Exec does not contain a voice dictation mode, but it can easily be used with tools like [Handy](https://handy.computer). It also does not include a native file viewer, but it does include / commands to open the current workspace in either the Finder or Terminal to easily check e.g. `git status` there.


## Get started

Needs to be built from source. Requires macOS 14+, Xcode 26 or later (including the Swift toolchain and Icon Composer asset compiler).

```sh
cd macOS
./scripts/build-app.sh
```

## Keyboard controls

| Action                          | Shortcut            |
| ------------------------------- | ------------------- |
| New conversation                | ⌘T                  |
| Switch conversations            | ⌘1 - ⌘9             |
| Detach conversation             | ⌘D                  |
| Move detached conversation back | ⌘W                  |
| Delete conversation             | ⌘⇧Delete            |
| Interrupt turn                  | Escape              |

Slash commands: `/model`, `/reasoning`, `/auto-approve`, `/compact`, `/workspace`, `/finder`, `/terminal`.

![Exec screenshot](screenshot.png)

## Development

[Sparkle](https://sparkle-project.org/) provides native in-app updates. Open `macOS/Package.swift` in Xcode, or run from `macOS/`:

```sh
./scripts/test.sh
./scripts/build-app.sh
```

Tests use isolated stores and fake transports, not your Keychain or live model calls. The Settings tests inject update actions and do not start Sparkle.

## Updates

Exec silently checks for updates on launch and when activated again, at most once every six hours during a run. A blue **Update available** badge at the bottom of the sidebar opens Sparkle's standard update flow. Its × dismisses the badge for that build, including after relaunch; a newer build can show it again. Silent checks do not download or install updates or open dialogs.

You can always use **Settings → Updates → Check for Updates…**, including for a dismissed update. Sparkle handles download verification, installation, and relaunch with its standard macOS interface.

The update feed lives in [`docs/appcast.xml`](docs/appcast.xml) and is served by GitHub Pages. See [RELEASING.md](RELEASING.md) for signing keys, Pages setup, and publishing updates.

For consistent Keychain access across rebuilds, configure a stable signing certificate:

```sh
security find-identity -v -p codesigning
git config --local exec.signingIdentity "<certificate SHA-1>"
REQUIRE_STABLE_SIGNING=1 ./scripts/build-app.sh
```
