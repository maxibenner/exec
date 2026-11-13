# Exec relay

Opaque, ephemeral WebSocket forwarding for the headless Rust agent and iOS client. No provider credentials, conversation storage, inference, or command retries live here.

## Local development

```sh
cd relay
cargo run --locked
```

Listens on `127.0.0.1:8787`. In the Mac app, open **Settings → Remote Access**, enable remote access and **Local development relay**, use `ws://127.0.0.1:8787`, and save. Create a pairing QR/invitation once the relay is connected.

The iOS Simulator can reach the Mac's loopback address. For a physical phone, explicitly bind to a private interface with `EXEC_RELAY_BIND=192.168.x.x:8787` and configure the same LAN address in the Mac settings **before pairing**. Both devices must share the network. Local `ws://` is explicitly opt-in; application payloads remain end-to-end encrypted. Do not expose plaintext host registration traffic to the internet.

## Docker, behind your reverse proxy

Build from this folder:

```sh
docker build -t exec-relay .
docker run -d --name exec-relay --restart unless-stopped \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1:8787:8787 exec-relay
```

The container runs as UID 10001 and needs no volume. It serves HTTP/WebSockets on port 8787. Configure your external reverse proxy to:

- Terminate valid public TLS; configure `wss://your-relay-host` in Exec.
- Forward `/v1/host` and `/v1/client/*` with WebSocket upgrades and `Authorization` intact.
- Disable request retries and response buffering; allow idle sockets for at least 90 seconds (20-second keepalives).
- Avoid logging Authorization, frames, or request bodies. Routing IDs are not credentials but should not be used for tracking.
- Apply appropriate IP/connection/rate limits; do not expose the container port directly.

`GET /health` returns `ok`. There is no provider/agent health information on this endpoint.

## Limits and trust

- One outbound host socket per host credential; up to four simultaneous phone connections per host and 64 hosts per process.
- One-MiB WebSocket frames, bounded queues, and 10-second send deadlines. Slow clients disconnect rather than buffering indefinitely.
- Host routes derive from a private host credential; a client cannot register itself as that host by knowing its routing ID.
- The relay has no account system. Host registration is open within its global bounds. This is a small self-hosted service, not an abuse-resistant public relay platform; use proxy limits/access restrictions appropriate to your deployment.
- Disconnecting a host closes its phone sockets and discards transient messages. Nothing is stored or delivered later.
- With no clients, only keepalive pings flow: the host does **not** stream conversation/settings updates. iOS polls while foregrounded and stops on backgrounding. Mac-local observation never crosses the relay.
- Changing the relay address requires distributing a new invitation to the phone. Disabling remote access preserves pairings; revocation removes the device and closes established sessions. Already accepted commands are not undone.

See [remote access architecture and security](../docs/remote-access.md) and [iOS setup](../iOS/README.md).
