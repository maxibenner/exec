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

Exec prefers accessibility-first control for desktop tasks:

- `open_app` opens an installed app by exact name or bundle identifier and returns its focused-window UI state. No Finder navigation is needed.
- `inspect_ui` reads a compact accessibility view of that window without activating the app or taking a screenshot.
- `ui_action` presses or focuses a referenced control, or replaces a supported text field's entire value. It returns updated UI state in the same call after a short settling delay; it does not poll or retry the action.

These text-based tools also work with text-only models. Each observation provides a single-use snapshot ID and element IDs, valid for 120 seconds. Actions recheck the app, window, element identity, supported action, and current value; window movement alone does not invalidate semantic targets. Reads are limited to 160 visited elements, eight levels, approximately two seconds of traversal, and 24 KB of output. Protected fields are omitted, and replacing an unreadable or oversized value is not offered. An incomplete tree or unsupported control may require the visual fallback.

With an image-capable model, `take_screenshot` and `computer_use` remain available for visual inspection and coordinate-based clicks, scrolling, typing, and keyboard shortcuts on the main display.

Computer control needs explicit approval independently of workspace Auto mode, plus macOS **Accessibility** permission. Its session permission covers both input and accessibility inspection: UI text and input arguments are shared with the model and saved in the conversation. Screenshots still require their own approval and macOS **Screen Recording** permission; the accessibility tools do not require Screen Recording. Grant permissions in System Settings → Privacy & Security; denied or interrupted operations are not automatically retried.

**Stop** revokes session computer control. Bring Exec forward to stop the current turn; the shortcuts are not global. Already delivered actions cannot be undone. Session permission and element references are not saved across restarts or conversation replacement. All sessions and both control paths share exclusive desktop access while an operation runs.

This is not a sandbox or a guarantee of UI correctness. An accepted action is not proof of task success: check the returned state, or use a screenshot for appearance-dependent tasks. A failed follow-up read does not repeat the preceding action. Exec cannot target itself. Do not use these tools for passwords or secrets or to operate security prompts. Coordinate input still requires fresh desktop captures and rejects changed geometry or obscured targets; keyboard input requires a verifiable focused window fully on the main display. Letter shortcuts use US virtual-key positions. Dragging, multi-display coordinate control, browser automation, and app-specific scripting are not included.

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
