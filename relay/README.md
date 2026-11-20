# Exec relay

Opaque, ephemeral WebSocket forwarding for the headless Rust agent and iOS client.

## Local development

```sh
cd relay
EXEC_RELAY_LOCAL_DEVELOPMENT=1 cargo run --locked
```

Listens on `127.0.0.1:8787`. In the Mac app, open **Settings → Remote Access**, enable remote access, use `ws://127.0.0.1:8787`, and save.

The iOS Simulator can reach the Mac's loopback address. Development admission accepts any syntactically valid host credential **only on a loopback listener** (`127.0.0.1` / `::1`). Never expose that listener through a public reverse proxy. The flag is rejected on wildcard/private/public binds and when an allowlist is also configured. Backend/client `localDevelopment` permits private-network plaintext WebSockets; it does not enable unrestricted relay admission.

For a physical phone on the LAN, bind `EXEC_RELAY_BIND=192.168.x.x:8787`, use that relay URL on the host, and configure the route allowlist below. Both devices must share the network. Non-loopback listeners require an allowlist even for LAN testing.

## Production host admission

There is no open-registration production mode. Without an allowlist or explicit loopback development mode, startup fails closed.

1. Enable remote access on each agent with its intended relay URL. A running relay is not needed to generate an invitation.
2. Generate a pairing invitation and copy **only its `route` field** into the relay's `EXEC_RELAY_ALLOWED_ROUTES`. It is the lowercase SHA-256 hash of the host's private registration token, not the token itself. Do not copy/log the invitation secret or `remote.json`.
3. Start/restart the relay with that allowlist. Create a fresh invitation for pairing if the earlier one expired.

```sh
export EXEC_RELAY_ALLOWED_ROUTES="<64-character lowercase route hash>,<another route hash>"
EXEC_RELAY_BIND=0.0.0.0:8787 cargo run --locked --release
```

The list is comma-separated, accepts surrounding whitespace, and supports at most 64 distinct routes. Empty/malformed entries fail startup. It is loaded at startup, not hot-reloaded: restart to add/remove hosts. Restart closes existing sockets; removed hosts cannot register again. Keep the list in deployment configuration; it contains no private host credentials and requires no credential database.

Registration still requires the private host token in `Authorization: Bearer …`; knowing an admitted route does not allow host impersonation. An unlisted token receives HTTP 403 **before** reserving a host slot. Removing a host from the allowlist is relay admission revocation, separate from revoking paired devices on that host.

## Docker setup

Build from this folder, with `EXEC_RELAY_ALLOWED_ROUTES` set as above:

```sh
docker build -t exec-relay .
docker run -d --name exec-relay --restart unless-stopped \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  -e EXEC_RELAY_ALLOWED_ROUTES="$EXEC_RELAY_ALLOWED_ROUTES" \
  -p 127.0.0.1:8787:8787 exec-relay
```

The container runs as UID 10001 and binds `0.0.0.0:8787` inside the container, so an allowlist is mandatory even when its published port is host-loopback-only.

Reverse proxy setup:

- Terminate valid public TLS; configure `wss://your-relay-host` in Exec.
- Forward `/v1/host` and `/v1/client/*` with WebSocket upgrades and `Authorization`.
- Disable request retries and response buffering. Allow idle sockets for at least 90 seconds (20-second keepalives).
- Apply appropriate IP/connection/rate limits as defense in depth, not as a substitute for admission.

`GET /health` returns `ok`. There is no provider/agent health information. Payloads remain opaque. The 1 MiB limit includes serialized relay-envelope overhead/JSON escaping; an oversize client envelope closes only its sender, not the host or other clients. Endpoint paths and relay envelope format remain v1; the agent/client authenticated handshake is now v2 (see [remote access](../docs/remote-access.md)).

## Verification

```sh
cargo test --locked
cargo build --locked
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --check
```

All relay tests use loopback sockets and synthetic tokens. They cover admission/configuration rejection, attempts to exhaust host slots with self-issued tokens, exact serialized size boundaries, JSON-escaping expansion and isolation of an oversize sender from a second client.
