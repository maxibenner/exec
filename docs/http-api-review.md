# HTTP API review and frontend configuration

## Review outcome

The transport migration retained the right architecture: one Rust HTTP dispatcher delegates to the existing manager/runtime/providers/tools. There is no second agent loop, proxy API, production CLI client, or duplicated conversation store. The test-only client is not part of the shipped library/application.

The original migration was not safe to expose as shipped: it defaulted to all interfaces without authentication, rejected loopback binding, and removed native process attestation without replacing that trust boundary. The Swift client also assumed every backend workspace was a local Mac folder.

Corrections:
- Default to `127.0.0.1:8765`; permit explicit interface/wildcard binding.
- Validate a single administrator bearer token before any HTTP body/route effects. Reads, health and event streams are protected too. Duplicate authorization headers fail closed.
- Permit unauthenticated operation only with the explicit `--insecure-no-auth` flag behind externally enforced access control. Missing credentials never silently choose this mode.
- Independently authorize native registration, OS-permission reports, results and desktop grants. A general API token is not a screenshot grant.
- Align Swift with authenticated owned/external endpoints, normal TLS trust, host-based workspace paths and external-service ownership.

Authentication is a small HTTP-boundary check (`service_auth.rs`), not middleware that owns another runtime or provider state. It uses the existing `ring` dependency for constant-time HMAC verification; no new dependencies or account framework were added. Provider authentication is unchanged and remains in providers.

Swift keeps its single bounded HTTP/NDJSON transport on Network.framework. It opens a fresh connection per request, does not follow redirects/use ambient proxies, and never retries a request. The existing bounded HTTP framing code is retained to preserve those cancellation/replay guarantees; it is not another API implementation. TLS verification is supplied by Network.framework without custom trust callbacks or HTTP fallback.

## Authenticate any trusted client

Provision a token once through a trusted channel:

```sh
export EXEC_AGENT_TOKEN="$(openssl rand -hex 32)"
./exec-agent --profile /absolute/private/profile --workspace-tools
```

Every request includes:

```http
Authorization: Bearer <64-hex-API-token>
```

This is a shared administrator credential, not per-client identities/scopes. Every holder can manage provider settings, conversations and host tools. Keep it out of source control, URLs, logs and public JavaScript. Rotate by replacing the secret and restarting the backend, then updating clients. There is no public token-discovery endpoint. Tokens are unrelated to OpenAI/DeepSeek credentials and are never forwarded to providers or automatically inherited by shell tools.

Native apps, command-line HTTP consumers and server-side applications can connect directly. Browser Origin/Fetch-Metadata requests remain rejected; browser support requires a deliberate separate origin and credential design. This is not a multi-tenant service or an OS sandbox against same-user code.

## Swift configuration

### Owned helper (default)

Without `EXEC_AGENT_URL`, Swift launches its bundled helper:

| Variable | Behavior |
|---|---|
| `EXEC_AGENT_HOST` | Numeric bind IP, default `127.0.0.1`; `0.0.0.0`/`::` explicitly expose network interfaces |
| `EXEC_AGENT_PORT` | 1–65535, default `8765`; no discovery or fallback |
| `EXEC_AGENT_TOKEN` | Optional pre-provisioned API token; otherwise a fresh random token is generated per launch |

To connect other trusted frontends to the app-owned helper, set `EXEC_AGENT_TOKEN` in **the app's launch environment** and give that same value to those clients. Finder/LaunchServices do not necessarily inherit your terminal environment; launch the app executable from the configured environment or configure its launcher. The default ephemeral value is intentionally not printed or served by the API.

Swift always generates a separate, ephemeral native credential for its own adapter and passes both credentials through the child environment, not argv/readiness output. `EXEC_AGENT_NATIVE_TOKEN` is rejected in managed mode; use standalone hosting for separately provisioned adapters. Provider credential overrides are removed from the helper environment. The app still waits for its own child's readiness and authenticates health, never attaching silently to an unrelated process on an occupied port. Quit waits for that helper's cancellation/cleanup.

### External service

Configure the client before launching it:

```sh
export EXEC_AGENT_URL="https://agent.example.com"
# Inject the existing server's EXEC_AGENT_TOKEN securely; do not generate another value here.
macOS/dist/Exec.app/Contents/MacOS/Exec
```

- `EXEC_AGENT_URL` must be a concrete HTTP(S) origin, without credentials, path, query or fragment. Do not combine it with `EXEC_AGENT_HOST`/`EXEC_AGENT_PORT`.
- `EXEC_AGENT_TOKEN` is required. For an externally authenticated proxy/VPN deployment only, `EXEC_AGENT_INSECURE_NO_AUTH=1` explicitly omits the API header instead; it cannot be combined with a token. No proxy login UI or custom authentication scheme is implemented in Swift.
- HTTPS is required for non-loopback endpoints unless `EXEC_AGENT_ALLOW_INSECURE_HTTP=1` explicitly acknowledges protection by a tunnel/VPN or equivalent boundary. That flag does not itself encrypt anything. HTTPS uses normal system certificate/hostname verification, with no trust bypass or plaintext fallback.
- Swift does not launch or terminate the external service. Quit detaches and cancels local pending UI actions, not backend operations; explicit Stop remains an operation-targeted API action. Disconnecting a native channel still revokes its transient capture capability.
- New workspaces use an explicit absolute **backend-host path**, not the local file picker. Finder/Terminal actions are unavailable for external paths. Image attachment selection/upload remains client-local, as intended.
- Native capture is absent unless a separate `EXEC_AGENT_NATIVE_TOKEN` is explicitly provisioned to this frontend. Screenshots capture **this frontend's Mac**, not automatically the backend machine. OS permission and `/screenshots` session consent remain required.
- OpenAI browser authentication still uses `localhost:1455` on the backend host. Authenticate on that host or explicitly forward that callback port; the HTTP migration does not make it a remote OAuth redirect service.

## Network deployment

The Rust listener serves **HTTP only**. Authentication identifies trusted callers; it does not encrypt traffic.

Choose either:
1. HTTPS termination (for example Caddy/nginx) with the backend bound to loopback/private reachability. Forward Authorization, do not log secrets, disable upstream command retries and NDJSON buffering, and preserve long-lived observer connections.
2. An encrypted, access-restricted SSH/VPN tunnel. Only peers trusted with full agent privileges should be permitted.

Ordinary LAN reachability is not authentication or encryption. If using `--insecure-no-auth`, the proxy/VPN must actually enforce access and the direct backend port must not bypass it. Native capability authentication remains required even in this mode. No proxy, certificate-management subsystem, OAuth server or new network-facing service was added to Exec.

This follows the separation of HTTPS, endpoint access control, and credential protection described in the [OWASP REST Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/REST_Security_Cheat_Sheet.html). Exec is a private administrative harness, not an MCP server or a public multi-user API.

## Verification

- Full isolated Rust suite: authentication rejection before effects, duplicate/wrong credentials, separate native capability, explicit external-auth mode, safe binding, lifecycle/recovery, approvals, cancellation and existing provider fixtures.
- 62 macOS checks: authenticated actual Rust subprocess, NDJSON/native grants, external attach/detach without server termination, correct quit semantics, no redirect or interrupted-mutation replay, and rejection of an untrusted TLS certificate. Existing native transcript/selection/layout checks remain intact.
- Stable signed build, with the same bundled helper and no signing-identity changes.
- One-off authorized live HTTP smoke checks: OpenAI and DeepSeek Unicode streaming completed; OpenAI synthetic image input succeeded; protected image bytes/hash matched. Anonymous API access returned 401, and an ordinary API token could not register a native adapter (403). Temporary conversations/assets were removed and the helper exited cleanly. No live credentials or inference were added to automated tests.

Still unverified: an actual remote proxy/VPN deployment, successful public-certificate HTTPS, interactive remote OAuth and native macOS permission/capture UX, and cross-platform production deployment. Tests use isolated stores, synthetic HTTP credentials and fake capture—not the user's Keychain or screen.
