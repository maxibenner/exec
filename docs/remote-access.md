# Remote Access

Exec serves a minimal browser interface for conversations, messaging, stopping operations, and creating conversations in folders on the Mac. The Mac remains the source of truth: providers, tools, approvals, and conversation files stay there. No separate relay application or website deployment is needed.

## Setup

1. Install **Pangolin CLI 0.21.0** once, outside Exec. See the [official site installation instructions](https://docs.pangolin.net/manage/sites/install-site) and [0.21.0 downloads](https://github.com/fosrl/cli/releases/tag/0.21.0). Choose the macOS binary matching your Mac. Exec does not download/install software, execute an installer script, request administrator access, or install a system service. The CLI is distinct from the legacy standalone **Newt** binary.
2. Create a **site** in your Pangolin dashboard. Copy its Pangolin URL, Site ID, and Site Secret into **Exec → Settings → Remote Access**. These authenticate the Mac connector, not the browser. Exec discovers common installation locations, including Homebrew and `~/.local/bin`; use **Select…** for another executable. Finder-launched apps do not inherit your shell's PATH.
3. Create a resource on that site targeting **HTTP → `127.0.0.1:9417`**, served at its origin root (no path prefix):
   - **Public HTTPS:** require Pangolin authentication and grant access only to intended users/roles. Authentication must cover `/`, `/app.js`, `/style.css`, and **every `/api/*` route**, with no bypass rules. **A public resource with authentication disabled exposes Exec**, including conversations, readable Mac folders, and messages that can run tools. Do not expose an unauthenticated public raw TCP resource.
   - **Private:** require an authenticated Pangolin client and restricted private-resource permissions. Use the resource's browser URL, preferably HTTPS with a valid certificate. The destination on the Mac remains loopback HTTP.
4. Enter that browser address in **Resource URL**, for example `https://exec.example.com`. This is separate from the Pangolin dashboard URL and is used for Host/origin validation. Include a non-default port if the browser uses one. Leave it blank only for loopback-only access. One resource origin is supported in this version.
5. Choose **Apply**, then enable Remote Access. Open the resource URL in the browser, signing in through Pangolin if requested. **There is no additional Exec login.** For a local check, manually open `http://127.0.0.1:9417` on the Mac.

Exec always manages its own Pangolin connector; there is no listener-only or external-connector mode. Older saved configurations keep their connection details, but the former connector-mode setting is ignored. If any required site details or executable are missing, complete the setup and Apply before Remote Access can start. When moving a site from a manually started connector, stop that connector yourself before enabling it in Exec. Exec never adopts or terminates independently started Pangolin/Newt processes.

## Security boundary

Pangolin's public authentication/resource policies or its authenticated private client and permissions are the remote security boundary. **Any process that can reach the local listener, and anyone Pangolin permits through to the resource, can use Exec's remote functionality.** The folder picker is not a filesystem sandbox. Existing auto-approval settings apply; interactive tool approvals remain on the Mac.

Exec binds **only IPv4 loopback**, never the LAN or `0.0.0.0`. Do not forward a router port directly to it. Public proxies must preserve the browser's original **Host**, **Origin**, **Sec-Fetch-Site**, **X-Exec-Request**, Content-Type, and conditional-request headers. Keep frontend and API same-origin. Forward `X-Exec-Response` back to the browser; it distinguishes Exec API responses from proxy login/error pages. Do not cache responses or log request bodies or site credentials.

Host is explicitly allowlisted for the configured resource authority and the listener's `127.0.0.1`/`localhost` addresses. This applies to static assets as well as APIs, blocking arbitrary-host DNS-rebinding bootstrap. Browser mutations require an allowed exact same-origin Origin, an explicit request header, and JSON. Cross-site and same-site-but-not-same-origin fetches are rejected. A top-level GET navigation to the static `/` shell is allowed on an allowlisted Host so Pangolin sign-in redirects and dashboard links work; this exception never exposes API data or permits a mutation. There is no CORS support. Forwarded identity/Host headers are **not** trusted for authentication or to bypass origin checks.

Pangolin controls authorization; Exec does not treat its request/response marker headers as credentials. A public reverse proxy terminates TLS, so trust it with transcript traffic. Exec adds no separate end-to-end encryption layer.

## Credentials and reviewed CLI limitations

Exec saves the entire applied configuration as one value in the existing Keychain credential-store abstraction. A failed save leaves the previous usable configuration and running connector unchanged. Draft edits do not restart anything. No site secrets are stored in preferences, command arguments, URLs, shell history, or logs. The old Exec browser key is no longer read or validated; its Keychain item is deleted best-effort when configuration is loaded. The frontend removes stale `exec.key` browser storage without discarding drafts or uncertain-delivery records.

The [official configuration reference](https://docs.pangolin.net/manage/sites/configure-site) documents `PANGOLIN_ENDPOINT`, `SITE_ID`, `SITE_SECRET`, and `CONFIG_FILE`. Exec launches Foundation `Process` directly, never through a shell:

```text
pangolin up site --disable-ssh --log-level ERROR
```

Credentials are supplied only in the child's environment. The following limitations were investigated before adopting this launch setup:

- **Credential caching:** CLI 0.21.0 embeds Newt 1.20.0. Its websocket client writes resolved ID/secret/endpoint to its config file after a successful connection, even when they came from environment variables—not only when provisioning. There is no documented no-save flag. Exec sets the documented `CONFIG_FILE` override to **`/dev/null`**: reads are empty and direct writes are discarded. This avoids even a temporary plaintext credential file. It depends on the reviewed direct-write implementation and must be rechecked for new releases.
- **Unrelated configuration:** each probe/connector has a private, temporary `HOME` and working directory. The child receives a small allowlisted environment, not inherited `SUDO_USER`, config paths, account state, scripts, or proxy settings. Exec never reads or overwrites the user's Pangolin configuration. Temporary directories are removed on exit; an app/system crash may leave an empty/non-secret directory for the OS to clean up.
- **Self-update:** the site runner starts an internal auto-update loop that can replace the selected executable and re-exec. There is no public site no-update flag in this release. Exec uses the reviewed internal `NEWT_SYSTEM_SUBSTRATE=CONTAINER` switch to suppress it, along with `PANGOLIN_CLI_DISABLE_UPDATE_CHECK=true` and `PANGOLIN_CLI_DISABLE_COMPANION_MODE=true`. This is a compatibility workaround, **not a claim that Exec runs a container**; reported substrate may therefore be “container.” Automatic CLI upgrades are not supported. Install updates yourself after Exec has reviewed/supports them.
- **Version policy:** only **0.21.0** is accepted, rather than assuming future versions preserve the above behavior. The `version` probe has a timeout and bounded output. The CLI's version command may itself check GitHub for updates; it is run without site credentials and is never automatically retried. Missing, older, newer, and standalone Newt executables produce an actionable error.
- **Foreground supervision:** `up site` runs the tunnel in-process, not through a daemon. macOS re-exec uses the same PID. SSH integration is disabled, and no up/down scripts, provisioning, Docker integration, or native interfaces are configured. Connector output is discarded directly to `/dev/null`, so it cannot accumulate or leak secrets into Exec logs. A running subprocess alone is not proof of a connection; Exec uses the connector’s tunnel-health marker for the Settings indicator.

Source review: [CLI site entrypoint at 0.21.0](https://github.com/fosrl/cli/blob/0.21.0/cmd/up/site/site.go), [Newt credential persistence at 1.20.0](https://github.com/fosrl/newt/blob/1.20.0/websocket/config.go), and [self-update switch at 1.20.0](https://github.com/fosrl/newt/blob/1.20.0/updates/selfupdate.go).

## Connection indicator

Settings shows **Connected to Pangolin** in green or **Not connected** in yellow, inline with the Remote Access description. Exec supplies the documented `HEALTH_FILE` in the connector’s private temporary directory and checks it once per second while its owned process is running. A fresh directory for every launch prevents stale state from a previous connector. Disable, quit, configuration replacement, and unexpected process exit clear the indicator.

This reports **the connector’s Pangolin/WireGuard tunnel health**, not end-to-end browser reachability, Resource URL correctness, certificates, or resource access policies. It does not request a resource URL, inspect CLI logs, or replay any application command. The marker contains no credentials and is removed with the private temporary directory.

The reviewed Newt 1.20.0 implementation creates the marker after a successful tunnel ping and removes it after its failure threshold/reconnection logic declares the tunnel unhealthy. It does **not** rewrite the file on every successful ping, so file age is not treated as an expiration. Consequently a network loss or sleep/wake transition can take tens of seconds or longer to appear; this is not an instantaneous connectivity guarantee. See [site health configuration](https://docs.pangolin.net/manage/sites/configure-site) and [reviewed ping behavior](https://github.com/fosrl/newt/blob/1.20.0/newt/ping.go).

## Lifecycle and troubleshooting

Remote Access is off by default. Disabled startup does not read the remote Keychain item, open a listener, or launch a connector. Opening its Settings page explicitly loads configuration. Once enabled and configured, Exec waits for the loopback listener to be ready before launching the managed connector. The saved enabled state restores when the conversation library becomes available after relaunch. Commands are blocked during startup restoration.

Repeated toggles/view updates cannot create duplicate connectors. Applying configuration stops the old connector and server before starting the replacement, rotating the command epoch. Disabling closes HTTP connections and stops/reaps only the owned child; accepted chat turns continue independently. Normal app quit—including an idle quit—also stops it. Shutdown gives the owned process group two seconds for SIGTERM, then escalates to SIGKILL and reaps the child. Independently started connectors are untouched. Force-killing Exec or an OS crash is not a clean-quit path.

There is **no automatic process respawn** after a failed launch or unexpected exit. Correct the configuration or check the site/dashboard, then explicitly toggle Remote Access off and on. The connector's own network reconnection remains enabled and does not replay application commands. Enabling Remote Access alone does not keep an idle Mac awake, and it does not run while the app is closed.

- **CLI missing/unsupported:** install the reviewed release and select the actual executable, not a Newt binary or service wrapper. Check executable permissions and macOS download/Gatekeeper approval outside Exec.
- **Not connected while Exec has no launch error:** check the endpoint, ID/secret and network in Pangolin. Exec intentionally does not surface raw CLI logs or mark a running process connected without the tunnel-health marker.
- **403 / origin rejection:** check Resource URL, exact browser hostname/port, root-path routing, and preserved Host/Origin/request headers. Do not work around it with CORS or forwarded identity headers.
- **Cannot listen:** another app may occupy port 9417. Stop that conflicting listener; Exec never takes over another process.
- **Keychain failure:** previous saved credentials remain usable after a failed Apply. Resolve access/signing permissions and Apply again; no silent Keychain ACL relaxation is performed.
- **Unavailable server / expired Pangolin browser session:** the browser disables sending and prompts you to check the connection or reload to sign in to Pangolin. It neither follows login redirects for API calls nor reproduces Pangolin's login UI.

## Browser behavior and uncertain delivery

Select conversations without changing the Mac's current conversation or draft. New Conversation browses the **Mac's** folders; creation inherits its default model and tool-approval preference. Cancelling the folder picker creates nothing. Folder listings are shallow and bounded; hidden folders/app packages are omitted, but an absolute path can open a readable folder. Transcript Markdown is a safe minimal subset, tool output is literal, and images remain on the Mac.

Messages enter the existing pending-input flow. Stop identifies the displayed operation, so a delayed stop cannot cancel a later turn. Tool approvals remain on the Mac. The browser polls read-only state while visible and never queues commands for later delivery. Drafts and uncertain receipts remain in tab session storage; closing/clearing the tab removes them (browser session restoration may retain them). To end remote authorization, use Pangolin's session/access controls; Exec has no misleading “Lock” action.

Each command has a unique request ID and server epoch. Deduplication records are not evicted within an epoch. Old epochs are rejected after restart, disable/re-enable, or applying configuration. Creation also uses its request ID as the saved conversation ID, preventing overwrite across epochs. HTTP request-size limits and cancellation remain in force.

**Messages, stop commands, and conversation creation are never automatically replayed.** A response can be lost after the command ran. Sending stays blocked behind the delivery-unconfirmed warning until you check its read-only receipt or deliberately dismiss it. After a server restart, a missing receipt does not prove the command failed; inspect the conversation/Mac. Proxy login/error responses without Exec's response marker also preserve uncertainty. Acceptance means the Mac accepted the operation, not that it completed or was durably saved against every possible crash.

## Verification

From `macOS/`:

```sh
./scripts/test.sh
./scripts/build-app.sh
```

Automated tests use fake launchers, disposable subprocess scripts, in-memory credentials, temporary stores, fake model providers, ephemeral loopback ports, and an isolated WebKit data store. Coverage includes missing/unsupported executables, environment isolation, save failures, startup ordering, duplicate suppression, shutdown/escalation/reaping, late callbacks, unexpected exits, explicit restart, disabled startup, relaunch, external-process preservation, login-free browsing, Host/origin checks, bounded HTTP framing, command identity/cancellation, conversation integrity, folder creation, and lost-response reconciliation. No test uses the user's Keychain, real site credentials, or live inference.

A separate check of the official macOS ARM64 CLI 0.21.0 binary (release SHA-256 verified) confirmed its version, foreground behavior, and SIGTERM exit using an isolated HOME and fake credentials against an unreachable loopback endpoint. No files were produced. This **does not** verify successful credential authentication, live tunneling, or network recovery.

Manual deployment checks still required:

- Public HTTPS over cellular and Wi-Fi: authorized user succeeds; anonymous and disallowed users cannot load frontend **or any API route**.
- Private resource: authenticated allowed client succeeds; disconnected/unauthorized clients fail.
- Correct credentials make the site online; invalid credentials fail without exposing credentials in logs/files.
- Quit/relaunch with the real connector, rapid toggles, and configuration changes leave only the intended owned connector and leave independently started processes untouched.
- Sleep/wake and network changes reconnect without command replay. Verify site state in Pangolin and both indicator transitions, allowing for the connector’s failure-detection delay.
- Expire a real Pangolin browser session, reload/sign in, then reconcile any uncertain command without resending it.
- Native Settings and iPhone Safari in light/dark mode, keyboard layout, folder selection, tool approvals, and stopping a harmless turn.
- Stable-signing Keychain permissions on the installed app. Fake-store tests do not validate live Keychain prompts or Pangolin service behavior.
