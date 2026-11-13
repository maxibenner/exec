# HTTP API review and frontend configuration

## Review outcome

The transport migration retained the right architecture: one Rust HTTP dispatcher delegates to the existing manager/runtime/providers/tools. There is no second agent loop, proxy API, production CLI client, or duplicated conversation store. The test-only client is not part of the shipped library/application.

The original migration was not safe to expose as shipped: it defaulted to all interfaces without authentication, rejected loopback binding, and removed native process attestation without replacing that trust boundary. The Swift client also assumed every backend workspace was a local Mac folder.

Corrections:
- Default to `127.0.0.1:8765`; permit explicit interface/wildcard binding.
- Validate a single administrator bearer token before any HTTP body/route effects. Reads, health and event streams are protected too. Duplicate authorization headers fail closed.
- Permit unauthenticated operation only with the explicit `--insecure-no-auth` flag behind externally enforced access control. Missing credentials never silently choose this mode.
- Independently authorize native registration, OS-permission reports, results and desktop grants. A general API token is not a screenshot grant.
- Keep Swift tied to its authenticated bundled helper; leave standalone backend hosting and other frontends independent.

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

## Swift bundled backend

The current macOS app **always launches its bundled `exec-agent` helper** and connects to
`127.0.0.1:8765`. It has no external-backend selection mode, endpoint discovery or fallback.
`EXEC_AGENT_URL`, `EXEC_AGENT_HOST`, `EXEC_AGENT_PORT`, API/native token overrides and insecure
transport flags cannot redirect or reconfigure the app's connection. Standalone `EXEC_AGENT_*`
settings are removed from the child environment before provisioning fresh private API/native
credentials. A port conflict fails startup instead of attaching to another server.

Swift generates separate ephemeral API and native credentials per helper launch and passes
them through the child environment, not argv/readiness output. Provider credential overrides
are removed so onboarding manages the app's own profile. The app waits for its own child's
readiness, authenticates health, starts the native channel and owns orderly helper shutdown.
Quit cancels and awaits work rather than detaching from a remotely managed service.

Workspaces use the local Mac folder picker and Finder/Terminal actions. Screenshot capture
stays in Swift on that Mac, with OS permission, explicit per-conversation enablement and
exact request/result correlation. The Rust backend never implements headless capture.

Standalone Rust hosting retains its configurable binding and authentication for other
trusted frontends and future server deployments. Those capabilities do **not** make the
current Swift app an arbitrary server client. A future native adapter would independently
need its own capture implementation, OS permissions and separately provisioned native
credential; an ordinary API token alone cannot enable capture.

## Network deployment

The Rust listener serves **HTTP only**. Authentication identifies trusted callers; it does not encrypt traffic.

Choose either:
1. HTTPS termination (for example Caddy/nginx) with the backend bound to loopback/private reachability. Forward Authorization, do not log secrets, disable upstream command retries and NDJSON buffering, and preserve long-lived observer connections.
2. An encrypted, access-restricted SSH/VPN tunnel. Only peers trusted with full agent privileges should be permitted.

Ordinary LAN reachability is not authentication or encryption. If using `--insecure-no-auth`, the proxy/VPN must actually enforce access and the direct backend port must not bypass it. Native capability authentication remains required even in this mode. No proxy, certificate-management subsystem, OAuth server or new network-facing service was added to Exec.

This follows the separation of HTTPS, endpoint access control, and credential protection described in the [OWASP REST Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/REST_Security_Cheat_Sheet.html). Exec is a private administrative harness, not an MCP server or a public multi-user API.

## Verification

- Full isolated Rust suite: authentication rejection before effects, duplicate/wrong credentials, separate native capability, explicit external-auth mode, safe binding, lifecycle/recovery, approvals, cancellation and existing provider fixtures.
- 61 macOS checks: authenticated actual Rust subprocess, NDJSON/native grants, bundled-only configuration and inherited-setting isolation, owned-helper quit semantics, no redirect or interrupted-mutation replay, and transport rejection of an untrusted TLS certificate. The external attach/detach mode and its obsolete checks have been removed. Existing native transcript/selection/layout checks remain intact.
- Stable signed build, with the same bundled helper and no signing-identity changes.
- One-off authorized live HTTP smoke checks: OpenAI and DeepSeek Unicode streaming completed; OpenAI synthetic image input succeeded; protected image bytes/hash matched. Anonymous API access returned 401, and an ordinary API token could not register a native adapter (403). Temporary conversations/assets were removed and the helper exited cleanly. No live credentials or inference were added to automated tests.

Still unverified: an actual remote proxy/VPN deployment, successful public-certificate HTTPS, interactive remote OAuth and native macOS permission/capture UX, and cross-platform production deployment. Tests use isolated stores, synthetic HTTP credentials and fake capture—not the user's Keychain or screen.
