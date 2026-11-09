<p align="center">
  <img src="macOS/Resources/Glass_Icon.png" alt="Exec glass app icon" width="64" height="64">
</p>

# Exec

A minimal, native macOS coding agent. Starts up lightning fast and offers hotkeys for quick navigation and config changes.

Currently supports OpenAI via subscription and DeepSeek via API key.

[Download for MacOS](https://github.com/maxibenner/exec/releases/latest/download/Exec-macOS-arm64.dmg)

# Philosophy

Exec is not meant to be the everything-app. It is purposefully kept minimal to slot into existing workflows. E.g. Exec does not contain a voice dictation mode, but it can easily be used with tools like [Handy](https://handy.computer). It also does not include a native file viewer, but it does include / commands to open the current workspace in either the Finder or Terminal to easily check e.g. `git status` there.


## Get started

To build from source, use Xcode 26 or later (including the Swift toolchain and Icon Composer asset compiler):

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

## Computer use

With an image-capable model, Exec can activate an application, click/double-click/right-click, scroll, type ordinary text, and send named keys or shortcuts on the main display. Ask for a concrete task; the model uses `take_screenshot` to observe and `computer_use` for one action at a time.

Computer control needs explicit approval independently of workspace Auto mode, plus macOS **Accessibility** permission. Screenshots still require their own approval and macOS **Screen Recording** permission. Grant these in System Settings → Privacy & Security; a denied or interrupted operation is not automatically retried. For an uninterrupted observe/action loop, you can separately allow screenshots and computer control for the session. One-time screenshot approval can bring Exec forward; activation and a fresh target-app capture may then be needed.

**Stop** revokes session computer control, as does **Revoke Computer Control** in the composer. Bring Exec forward to use these controls; the shortcuts are not global. Returning to another application during typing stops further input. Already delivered input cannot be undone. Session control permission is not saved across restarts or conversation replacement.

This is conservative, screenshot-driven control, not a sandbox or a guarantee of UI correctness. Input uses short-lived, single-use desktop captures and rejects changed focus, window geometry, obscured pointer targets, and secure-input mode. Keyboard input requires a verifiable focused window fully on the main display. Exec cannot target itself. Window screenshots are inspection-only; dragging, multi-display control, and accessibility-tree navigation are not supported. Letter shortcuts use US virtual-key positions; Unicode text entry can be unsupported by some apps. Do not use this for passwords or secrets: tool arguments and screenshots are saved in the conversation and shared with the model.

## Development

Open `macOS/Package.swift` in Xcode, or run from `macOS/`:

```sh
./scripts/test.sh
./scripts/build-app.sh
```

Tests use isolated stores and fake transports, not your Keychain or live model calls.

For consistent Keychain access across rebuilds, configure a stable signing certificate:

```sh
security find-identity -v -p codesigning
git config --local exec.signingIdentity "<certificate SHA-1>"
REQUIRE_STABLE_SIGNING=1 ./scripts/build-app.sh
```
