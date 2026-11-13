# Test parity and migration verification

The TypeScript baseline at migration time passed **106 reported tests** (`npm run check`, `npm test`). That includes one parent test grouping 11 invalid-response subtests: there are **105 behavioral leaf cases**.

The Rust suite ports those behavioral cases, rather than replacing them with smoke tests. It currently reports **110 tests**: the same 105 cases, two child-process fixture entrypoints, and three Rust-specific ownership/backpressure/ordering regressions. No tests are ignored. The fixture entrypoints return immediately in the parent harness; their substantive assertions execute in isolated subprocesses launched by the corresponding parent tests.

| Original TypeScript suite | Rust suite | Behavioral cases | Preserved scenarios |
|---|---|---:|---|
| `credentials.test.ts` | `tests/credentials.rs` | 12 | Private JSON/custom paths/environment precedence; six invalid-key cases; malformed/oversized/unknown JSON; ownership/permissions/symlinks; transport-only credential use; real foreground startup/signals/reopening; invalid startup without profile creation |
| `deepseek.test.ts` | `tests/deepseek.rs` | 25 | Concrete request encoding; split UTF-8/CR/LF/SSE; fragmented calls withheld until completion; all 11 malformed/incomplete/unsupported batches; bounded UTF-8/frame failures; sanitized HTTP failures/body disposal; credential/transport errors; pre-cancel/missing keys; stalled-body deadlines; pre-header cancellation; late credentials; body/content type; concurrent cancellation isolation; neutral model metadata; approved real edits and durable continuation; explicit tool outcomes in wire context |
| `lifecycle.test.ts` | `tests/lifecycle.rs` | 8 | Live ownership versus approval/intent; cancellation cleanup; no restored ownership; denial/cancelled approval/preparation failure/executor failure/completion; exactly one tool result per finalized call on failed intent/result checkpoints |
| `persistence.test.ts` | `tests/persistence.rs` | 14 | Round-trip/continuation/deletion; abrupt subprocess exit at partial/approval/tool boundaries; exclusive lock and captured records; corrupt/unsupported/linked data; result ordering validation; pre-inference checkpoint failure; intent/result failure recovery; terminal save ordering; saved-but-unacknowledged intent; retained references and manager close |
| `runtime.test.ts` | `tests/runtime.rs` | 14 | Streamed text/context/observer isolation; exact single-use approvals; denial; cancellation and paired calls; interrupted partial context; incomplete/duplicate calls; cleanup ownership; safe errors/no retry; step limit; pre-start cancellation; approval/execution handoff; preparation failure; independent concurrent conversations |
| `service.test.ts` | `tests/service.rs` | 14 | Real-socket creation/stream/reconnect/persistence; exclusion/concurrency/cancel; approval and denial; shutdown with pending approval; strict request/browser validation; private endpoint ownership; sanitized model/runtime errors; transcript escaping/reconciliation; real CLI commands; shutdown/disconnect; lost mutation response/no replay; live deltas; tool ownership/events/cancellation acceptance |
| `tools.test.ts` | `tests/tools.rs` | 18 | Full revisions/UTF-8/limits; path/link/binary/size refusal; literal bounded search; approval-free preparation/exact edits/mode; stale/nonunique/concurrent edits; creation races/cancel; ancestor substitution; runtime revision failure; shell approval/workspace/output/exit codes; clean environment; output bounds; timeouts; TERM-resistant process groups; cancellation diagnostics/no inference; denial; executor-return/result-publication cancellation boundaries |

Rust-specific tests in `tests/rust_adaptations.rs` verify that dropping a completion receipt cannot abort the owned runner, a stalled observer cannot grow its queue without bound or stop execution, and serialized checkpoint writes preserve acquisition order.

## Language adaptations

- JavaScript exceptions become typed `Result` errors. The synchronous-executor-throw scenario is an error from the first poll of an async Rust executor; the start/result ordering assertions remain.
- Owned snapshots/requests and immutable shared event values replace JavaScript mutation-defense copies. Observers receive bounded channels rather than synchronous callbacks, so a disconnected/panicking consumer cannot run inside the agent's execution path.
- Cancellation at tool-result publication is synchronized with the immediately following checkpoint, rather than a JavaScript callback. It still asserts the result remains completed, the containing operation becomes interrupted, effects occur once, and no further inference runs.
- Tests use Rust subprocess fixtures instead of Node fixtures. The crash boundaries still exit abruptly without closing the store; recovery explicitly removes only the temporary test profile's lock after child exit.
- Tests inject an explicit credential value/transport instead of replacing `globalThis.fetch` or mutating process-wide environment variables. Shell environment isolation uses a separate process, avoiding unsafe environment mutation in parallel Rust tests.
- Concurrent edits assert exactly one approved revision wins; thread scheduling does not promise which simultaneously submitted edit wins. No new queueing policy is introduced.

## Commands

```sh
# From agent-rust/
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked --all-targets
cargo build --locked --release
```

Additional interoperability smoke check performed against the original implementation, using isolated profiles and a fake provider:

- Rust CLI creates, sends and inspects a conversation hosted by the TypeScript service, including streamed Unicode text.
- Rust service reopens the completed TypeScript record without inference.
- Original TypeScript client reads the Rust service's snapshot/event stream and creates a conversation.
- Original TypeScript record validator and store load the Rust-created record after normal shutdown.

This verifies those tested compatibility paths, not every possible mixed-version/client scenario. Both implementations retain the same API v1 and version-1 record shapes. Never share a profile between simultaneous hosts.

Verified on macOS with Rust 1.93.1. Live DeepSeek requests, interactive TTY input, Linux execution, power-loss durability guarantees and Swift integration remain unverified. No real credentials, Keychain entries or paid inference were used.
