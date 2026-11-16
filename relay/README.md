# Exec relay

Opaque, ephemeral WebSocket forwarding for the headless Rust agent and iOS client.

## Local development

```sh
cd relay
cargo run --locked
```

Listens on `127.0.0.1:8787`. In the Mac app, open **Settings → Remote Access**, enable remote access, use `ws://127.0.0.1:8787`, and save.

The iOS Simulator can reach the Mac's loopback address. For a physical phone, explicitly bind to a private interface with `EXEC_RELAY_BIND=192.168.x.x:8787` and configure the same LAN address in the Mac settings before pairing. Both devices must share the network.

## Docker setup

(Build from this folder)

```sh
docker build -t exec-relay .
docker run -d --name exec-relay --restart unless-stopped \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1:8787:8787 exec-relay
```

The container runs as UID 10001. It serves HTTP/WebSockets on port 8787.

Revers proxy setup:

- Terminate valid public TLS; configure `wss://your-relay-host` in Exec.
- Forward `/v1/host` and `/v1/client/*` with WebSocket upgrades and `Authorization`.
- Disable request retries and response buffering. Allow idle sockets for at least 90 seconds (20-second keepalives).
- Apply appropriate IP/connection/rate limits.

`GET /health` returns `ok`. There is no provider/agent health information.