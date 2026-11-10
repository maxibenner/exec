# Remote Access

Exec serves a minimal mobile web frontend for conversations, including creating a new conversation in a folder on the Mac. The Mac remains the source of truth: all providers, tools, approvals and conversation files stay there. No separate relay application or website deployment is needed.

## Enable on the Mac

1. Build/install Exec, then open **Settings → Remote Access**.
2. Turn on **Enable Remote Access**.
3. Exec listens at **`http://127.0.0.1:9417`**. Use **Open Local Frontend** to check it locally.
4. Choose **Copy Access Key**. Transfer it privately to your phone; do not put it in a URL, configuration repository, screenshot, or support log.

Remote Access is **off by default**. While disabled, Exec creates no listener and does not read its remote access credential. Turning it off closes the listener and all remote connections immediately, without cancelling already accepted agent turns. The preference survives app restarts. If enabled on restart, the listener starts when the conversation library is available; commands remain blocked during the read-only startup presentation.

New access keys contain **four short lowercase words separated by dashes**, for example `apple-boat-cloud-drift` (example only, not a real key). Each word is selected independently using the OS cryptographic random source from 1,295 words: about **41 bits of entropy**, less than the old 256-bit keys. Always keep Pangolin authentication/access control enabled; the short key is not intended to be the sole protection for an internet-facing service.

Keys stay in the Mac's existing Keychain service, not preferences. Existing 64-character keys remain valid until **Reset Key…** generates a four-word key and revokes every browser using the previous key. There is one shared key, not individual device accounts. It grants access to conversations, Mac folder names/paths, and messages that can run tools; keep it private.

The bundled vocabulary is adapted from the Electronic Frontier Foundation's [Short Wordlist #1](https://www.eff.org/files/2016/09/08/eff_short_wordlist_1.txt), under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) per [EFF's copyright policy](https://www.eff.org/copyright). The hyphenated entry `yo-yo` is omitted so all keys have exactly four parts.

## Pangolin with Newt on this Mac

Run Newt **directly on the Mac**, connected to your Pangolin site. A Newt process on another machine, or inside a container with its own loopback interface, cannot reach Exec's `127.0.0.1`. Exec intentionally does not expose a LAN listener or open router ports.

### Step 1: connect this Mac as a site

1. In your Pangolin dashboard, create a **site** for this Mac (for example, `Exec Mac`) and copy its Newt configuration. Reuse an existing site only if its connector already runs directly on this Mac.
2. Install the macOS Newt binary using the [official Newt installation instructions](https://docs.pangolin.net/manage/sites/install-newt). The manual-download option avoids executing an installer script; choose the macOS architecture matching your Mac. Current Pangolin docs recommend the Pangolin CLI for new sites, but still support standalone Newt. These instructions use Newt because it can reach Exec directly on loopback.
3. Start Newt with the site's endpoint, ID and secret. These are **Pangolin credentials**, not the Exec access key. Use the configuration method shown by your dashboard. For example, Newt supports a protected JSON file:

   ```json
   {
     "id": "YOUR_SITE_ID",
     "secret": "YOUR_SITE_SECRET",
     "endpoint": "https://pangolin.example.com"
   }
   ```

   Save it outside your project repositories, readable only by your account (`chmod 600 /path/to/newt-config.json`), then run:

   ```sh
   CONFIG_FILE=/path/to/newt-config.json newt
   ```

   Do not paste the actual secret into chat or logs. Keep this process running for the initial test; closing it disconnects the site. A persistent macOS launch agent is a separate deployment step (the Linux systemd instructions do not apply on macOS).
4. Wait for the site to appear **online** in Pangolin. With Exec's Remote Access enabled, open `http://127.0.0.1:9417` on this Mac and verify the local login works before proceeding.

### Step 2: authenticated public HTTPS resource (browser only)

This is the simplest option for Safari without a phone-side Pangolin client. "Public" means the proxy URL is internet-reachable, **not** that authentication should be disabled.

1. In Pangolin, create a **public HTTP/HTTPS resource**, for example `Exec`.
2. Assign a hostname such as `exec.example.com` on a domain configured in your Pangolin install. Make sure its DNS points at the Pangolin server (or is covered by your existing wildcard DNS) and HTTPS has a valid certificate.
3. Add one target:

   | Field | Value |
   | --- | --- |
   | Site | The online site running on this Mac |
   | Upstream scheme | `HTTP` |
   | Host / address | `127.0.0.1` |
   | Port | `9417` |
   | Path | Root; no prefix or rewrite |

4. **Require Pangolin authentication** and grant access only to your user/role. Do not add bypass rules for `/api/*`, the login page, or static assets.
5. Leave any **custom Host header override unset**. Exec must receive the public hostname, not `127.0.0.1`, in the request's Host header.
6. On the phone, open `https://exec.example.com`, sign in to Pangolin, then enter the Exec access key. Use **Reset Key… → Copy Access Key** on the Mac if you still have the old long key.
7. Test over cellular as well as Wi-Fi. Keep the Mac awake, with both Exec and Newt running. No inbound router port forwarding to the Mac is needed.

See [Pangolin's public HTTP/HTTPS setup](https://docs.pangolin.net/manage/resources/public/http-https). Dashboard labels can vary by version.

### Alternative: private HTTPS resource (with the Pangolin phone client)

This fits a phone that already has Pangolin installed:

1. Create a **private HTTP/HTTPS resource** on the Mac's Newt site.
2. Give it a hostname on a domain configured in Pangolin, and enable SSL so the browser receives a valid certificate.
3. Set the destination scheme to **HTTP**, host to **`127.0.0.1`**, and port to **`9417`**.
4. Grant only your user access to that resource.
5. Connect the Pangolin client on the phone, then open the resource's **HTTPS URL** in Safari.
6. Enter the Exec access key.

Use current Pangolin/Newt versions that support private HTTPS resources. See [Pangolin's private HTTP/HTTPS setup](https://docs.pangolin.net/manage/resources/private/private-http).

### Proxy requirements

- Serve the resource at its domain root, not a path prefix. Keep the page, `/app.js`, `/style.css` and `/api/*` on the **same origin**.
- Preserve the browser's original **Host** header. Do not override it with `127.0.0.1`; command origin checks deliberately reject a mismatch.
- Forward `X-Exec-Key`, `Origin`, `Content-Type` and conditional-request headers. No CORS configuration is needed or supported.
- Do not cache API responses or log request bodies/access-key headers.
- Keep the frontend and API behind the same Pangolin access policy. Don't use an unauthenticated raw public TCP resource.
- The browser requires **HTTPS**, except for local testing on the Mac's loopback address. The destination between Newt and Exec remains HTTP over loopback.

A public reverse proxy terminates TLS on the VPS, so trust that server with transcript traffic. Pangolin's private HTTPS resource instead terminates TLS at the site connector, according to its documentation. Exec does not add an independent end-to-end encryption layer to either mode.

## On the phone

- Select an existing conversation, including conversations not currently selected on the Mac.
- Choose **New Conversation**, browse the **Mac's** folders, and choose **Use This Folder**. **Home**, **Up**, and an editable absolute path support navigation. This does not upload files or open the phone's file picker. Cancel creates nothing. Creation saves an empty conversation with the Mac's default model/effort and tool-approval preference, without changing the desktop selection or draft.
- Folder browsing is shallow and bounded; hidden folders and app packages are omitted from the list. Enter an absolute path to a hidden folder if needed. macOS permissions still apply. The access key permits browsing any readable folder on this Mac, not just existing workspaces; this picker is not a filesystem sandbox.
- Read assistant messages and expand tool cards to inspect arguments/results. Text uses a small Markdown subset; images remain on the Mac and are indicated in the transcript.
- Send text. During a turn it enters Exec's existing pending-input flow; it does not overwrite a desktop draft or switch the selected desktop conversation.
- Use **Stop** to cancel the displayed operation. A delayed stop cannot cancel a newer turn.
- Tool approvals remain on the Mac. Sending a new message can withdraw a pending approval, just like desktop input. Existing auto-approval settings still apply; new conversations inherit the Mac's default, without changing that default.
- **Lock** removes the access key from this browser tab and clears the displayed conversation. The key, phone drafts and any uncertain command are stored only in the tab's `sessionStorage`; no service worker or cloud history is used. Browser session restoration may retain tab storage. Close/clear the tab to discard local drafts as well.

Updates use one-second polling while the page is visible, with ETags to avoid retransmitting unchanged snapshots. After backgrounding or reconnecting, the browser obtains current Mac state rather than replaying an event log. The Mac must be awake, Exec must be running, and Newt must be connected. Exec does not prevent sleep or run as a background daemon.

### Interrupted connections

The frontend never automatically repeats a creation, message, or stop command. Each command has a unique ID and an Exec-service epoch; duplicates are recognized within that epoch, and stale epochs are rejected after restart, disabling/re-enabling, or key reset. Creation uses its request ID as the saved conversation ID, so even a replay with a new epoch cannot overwrite an existing conversation. A creation response can fail after the folder/session was saved: check its receipt and the conversation list before dismissing the warning and explicitly creating again.

If a response is lost, sending is blocked behind a **delivery-unconfirmed** warning. **Check Receipt** performs a read-only lookup. If the service restarted, a receipt might no longer exist even though the command ran. Check the transcript/Mac before dismissing the warning and choosing whether to send anything else. Acceptance acknowledges the Mac runner, not completion or crash-proof persistence. No commands are queued for later delivery while the Mac is offline.

## Development and verification

The API and loopback transport are in `macOS/Sources/Exec/Remote/`; the frontend is plain HTML/CSS/JavaScript in `macOS/Resources/RemoteUI/`. `scripts/build-app.sh` copies it into the signed app bundle. Running the unbundled SwiftPM executable alone does not install these assets.

From `macOS/`:

```sh
./scripts/test.sh
./scripts/build-app.sh
```

Tests use temporary conversations, fake providers, in-memory credentials, ephemeral loopback ports and an isolated WebKit data store. They cover authentication/origin checks, bounded HTTP framing, cold conversation access, command deduplication, cancellation, approval handling, short-key generation and legacy-key preservation, key revocation, disabled-listener behavior, folder browsing, workspace creation without desktop selection changes, mobile-width layout and lost-response receipt reconciliation (including creation). They do not verify a real Pangolin deployment, iPhone Safari, live inference or the user's Keychain permissions.

Manual deployment checks:

- Open the HTTPS resource on the phone over cellular, not only home Wi-Fi.
- Verify only your Pangolin user can reach it and the wrong Exec key cannot read conversations.
- Observe an existing turn, send a follow-up, and confirm the Mac's selected conversation/draft do not change.
- Create a conversation using a Mac workspace folder; verify the folder, default model and tool-approval setting on the Mac. Cancel another picker and confirm no conversation is added.
- Check the minimal layout, native controls and folder dialog on iPhone Safari in light/dark mode, including with the keyboard open.
- Check tool approval behavior and stop a harmless turn.
- Background Safari and reopen it; verify the transcript catches up.
- Disable Remote Access and verify the URL stops working; re-enable and reset the key to verify revocation.
- Confirm the Mac going to sleep disables sending rather than silently queuing input.
