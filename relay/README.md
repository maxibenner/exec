# Exec relay

Opaque, ephemeral WebSocket forwarding for the headless Rust agent and iOS client.

## Local development

```sh
cd relay
cargo run --locked
```

Listens on `127.0.0.1:8787`. In the Mac app, open **Settings → Remote Access**, enable remote access, use `ws://127.0.0.1:8787`, and save.

The iOS Simulator can reach the Mac's loopback address. No development flag or allowlist is needed. Backend/client `localDevelopment` permits private-network plaintext WebSockets; it does not change relay admission. The legacy `EXEC_RELAY_LOCAL_DEVELOPMENT=1` flag remains supported only on loopback binds with no allowlist, but is no longer necessary.

For a physical phone on the LAN, bind `EXEC_RELAY_BIND=192.168.x.x:8787` and use that relay URL on the host. Both devices must share the network. The optional route allowlist below works on any listener.

## Production host admission

By default, the relay accepts any backend on any bind address. Leaving `EXEC_RELAY_ALLOWED_ROUTES` unset, empty or whitespace-only enables open registration. This does not bypass host-token validation, device pairing or end-to-end encryption. Any backend can consume relay capacity in this mode; the limit remains 64 simultaneous hosts.

To restrict registration to specific backends:

1. Enable remote access on each agent with its intended relay URL. A running relay is not needed to generate an invitation.
2. Generate a pairing invitation and copy **only its `route` field** into the relay's `EXEC_RELAY_ALLOWED_ROUTES`. It is the lowercase SHA-256 hash of the host's private registration token, not the token itself. Do not copy/log the invitation secret or `remote.json`.
3. Start/restart the relay with that allowlist. Create a fresh invitation for pairing if the earlier one expired.

```sh
export EXEC_RELAY_ALLOWED_ROUTES="<64-character lowercase route hash>,<another route hash>"
EXEC_RELAY_BIND=0.0.0.0:8787 cargo run --locked --release
```

A nonempty list is comma-separated, accepts surrounding whitespace, and supports at most 64 distinct routes. Malformed hashes or empty entries within a list fail startup rather than enabling open registration. It is loaded at startup, not hot-reloaded: restart to change the policy. Restart closes existing sockets; clearing the entire list reopens registration. Keep the list in deployment configuration; it contains no private host credentials and requires no credential database.

Registration still requires the private host token in `Authorization: Bearer …`; knowing a route does not allow host impersonation. With an allowlist configured, an unlisted token receives HTTP 403 **before** reserving a host slot. Removing a host from a nonempty allowlist is relay admission revocation, separate from revoking paired devices on that host.

## Docker setup

Build from this folder. This example uses the default open registration:

```sh
docker build -t exec-relay .
docker run -d --name exec-relay --restart unless-stopped \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1:8787:8787 exec-relay
```

The container runs as UID 10001 and binds `0.0.0.0:8787` inside the container. To restrict backends, set the allowlist as above and add `-e EXEC_RELAY_ALLOWED_ROUTES="$EXEC_RELAY_ALLOWED_ROUTES"` to `docker run` before the image name.

For the repository-root `compose.yaml`, set `EXEC_RELAY_DOMAIN` and run `docker compose up -d --build`. Compose forwards the optional allowlist and accepts arbitrary backends when it is unset or blank. For restricted registration, follow the [private agent bootstrap](../docs/api.md#token-files-containers-and-local-administration): start only `agent` with `--no-deps`, configure remote access, obtain its public route hash via the interactive admin CLI, then set the allowlist before starting `relay proxy`. Never put the host registration token or invitation secret in Compose configuration/environment/logs. To apply an updated allowlist, recreate the relay container (`docker compose up -d --force-recreate relay`); a plain Compose restart keeps the old environment.

Reverse proxy setup:

- Terminate valid public TLS; configure `wss://your-relay-host` in Exec.
- Forward `/v1/host` and `/v1/client/*` with WebSocket upgrades and `Authorization`.
- Disable request retries and response buffering. Allow idle sockets for at least 90 seconds (20-second keepalives).
- Apply appropriate IP/connection/rate limits as defense in depth, especially with open registration.

`GET /health` returns `ok`. There is no provider/agent health information. Payloads remain opaque. The 1 MiB limit includes serialized relay-envelope overhead/JSON escaping; an oversize client envelope closes only its sender, not the host or other clients. Endpoint paths and relay envelope format remain v1; the agent/client authenticated handshake is now v2 (see [remote access](../docs/remote-access.md)).

## Verification

```sh
cargo test --locked
cargo build --locked
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --check
```

All relay tests use loopback sockets and synthetic tokens. They cover open registration with unset/blank allowlists, token validation, allowlist enforcement before reserving host slots, malformed configuration, exact serialized size boundaries, JSON-escaping expansion and isolation of an oversize sender from a second client. `cargo test --locked --test compose` checks the static Compose contract and, when the Docker CLI/Compose plugin is installed, renders unset, blank, valid and malformed allowlists with `docker compose config --format json`, then applies the real relay startup validator. Rendering needs no daemon, builds, registry access or credentials. Without the Docker CLI only the render portion is skipped; an installed but failing Compose command is reported, not retried. These checks do not verify Linux containers or public DNS/TLS.
