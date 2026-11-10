# Remote Access

Exec can serve a small mobile web frontend for **existing conversations**. The Mac remains the source of truth: all providers, tools, approvals and conversation files stay there. No separate relay application or website deployment is needed.

## Enable on the Mac

1. Build/install Exec, then open **Settings → Remote Access**.
2. Turn on **Enable Remote Access**.
3. Exec listens at **`http://127.0.0.1:9417`**. Use **Open Local Frontend** to check it locally.
4. Choose **Copy Access Key**. Transfer it privately to your phone; do not put it in a URL, configuration repository, screenshot, or support log.

Remote Access is **off by default**. While disabled, Exec creates no listener and does not read its remote access credential. Turning it off closes the listener and all remote connections immediately, without cancelling already accepted agent turns. The preference survives app restarts. If enabled on restart, the listener starts when the conversation library is available; commands remain blocked during the read-only startup presentation.

The 256-bit random access key is stored in the Mac's existing Keychain service, not preferences. **Reset Key…** revokes every browser using the previous key. This first version has one shared key, not individual device accounts.

## Pangolin with Newt on this Mac

Run Newt **directly on the Mac**, connected to your Pangolin site. A Newt process on another machine, or inside a container with its own loopback interface, cannot reach Exec's `127.0.0.1`. Exec intentionally does not expose a LAN listener or open router ports.

### Private HTTPS resource (with the Pangolin phone client)

This fits a phone that already has Pangolin installed:

1. Create a **private HTTP/HTTPS resource** on the Mac's Newt site.
2. Give it a hostname on a domain configured in Pangolin, and enable SSL so the browser receives a valid certificate.
3. Set the destination scheme to **HTTP**, host to **`127.0.0.1`**, and port to **`9417`**.
4. Grant only your user access to that resource.
5. Connect the Pangolin client on the phone, then open the resource's **HTTPS URL** in Safari.
6. Enter the Exec access key.

Use current Pangolin/Newt versions that support private HTTPS resources. See [Pangolin's private HTTP/HTTPS setup](https://docs.pangolin.net/manage/resources/private/private-http).

### Authenticated public HTTPS resource (browser only)

Alternatively, create a **public HTTP/HTTPS resource**, require Pangolin authentication, and restrict access to your user. Add a target on the Mac's site with scheme **HTTP**, host **`127.0.0.1`**, and port **`9417`**. Open its HTTPS URL, sign in to Pangolin, then enter the Exec key. The phone-side Pangolin client is not required for this mode.

See [Pangolin's public HTTP/HTTPS setup](https://docs.pangolin.net/manage/resources/public/http-https).

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
- Read assistant messages and expand tool cards to inspect arguments/results. Text uses a small Markdown subset; images remain on the Mac and are indicated in the transcript.
- Send text. During a turn it enters Exec's existing pending-input flow; it does not overwrite a desktop draft or switch the selected desktop conversation.
- Use **Stop** to cancel the displayed operation. A delayed stop cannot cancel a newer turn.
- Tool approvals remain on the Mac. Sending a new message can withdraw a pending approval, just like desktop input. Existing auto-approval settings still apply; remote access never enables them.
- **Lock** removes the access key from this browser tab and clears the displayed conversation. The key, phone drafts and any uncertain command are stored only in the tab's `sessionStorage`; no service worker or cloud history is used. Browser session restoration may retain tab storage. Close/clear the tab to discard local drafts as well.

Updates use one-second polling while the page is visible, with ETags to avoid retransmitting unchanged snapshots. After backgrounding or reconnecting, the browser obtains current Mac state rather than replaying an event log. The Mac must be awake, Exec must be running, and Newt must be connected. Exec does not prevent sleep or run as a background daemon.

### Interrupted connections

The frontend never automatically repeats a message or stop command. Each command has a unique ID and an Exec-service epoch; duplicates are recognized within that epoch, and stale epochs are rejected after restart, disabling/re-enabling, or key reset.

If a response is lost, sending is blocked behind a **delivery-unconfirmed** warning. **Check Receipt** performs a read-only lookup. If the service restarted, a receipt might no longer exist even though the command ran. Check the transcript/Mac before dismissing the warning and choosing whether to send anything else. Acceptance acknowledges the Mac runner, not completion or crash-proof persistence. No commands are queued for later delivery while the Mac is offline.

## Development and verification

The API and loopback transport are in `macOS/Sources/Exec/Remote/`; the frontend is plain HTML/CSS/JavaScript in `macOS/Resources/RemoteUI/`. `scripts/build-app.sh` copies it into the signed app bundle. Running the unbundled SwiftPM executable alone does not install these assets.

From `macOS/`:

```sh
./scripts/test.sh
./scripts/build-app.sh
```

Tests use temporary conversations, fake providers, in-memory credentials, ephemeral loopback ports and an isolated WebKit data store. They cover authentication/origin checks, bounded HTTP framing, cold conversation access, command deduplication, cancellation, approval handling, key revocation, disabled-listener behavior, mobile-width layout and lost-response receipt reconciliation. They do not verify a real Pangolin deployment, iPhone Safari, live inference or the user's Keychain permissions.

Manual deployment checks:

- Open the HTTPS resource on the phone over cellular, not only home Wi-Fi.
- Verify only your Pangolin user can reach it and the wrong Exec key cannot read conversations.
- Observe an existing turn, send a follow-up, and confirm the Mac's selected conversation/draft do not change.
- Check tool approval behavior and stop a harmless turn.
- Background Safari and reopen it; verify the transcript catches up.
- Disable Remote Access and verify the URL stops working; re-enable and reset the key to verify revocation.
- Confirm the Mac going to sleep disables sending rather than silently queuing input.
