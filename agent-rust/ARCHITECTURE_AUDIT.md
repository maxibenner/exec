# Backend parity architecture audit

## Review basis and result

Re-read the root `AGENTS.md`, all 18 principles in `GUIDING_PRINCIPLES.md`, the approved
ownership/scope contract in `PARITY.md`, and the original cross-platform architecture plan.
The later Rust/backend-parity decisions supersede the plan's initial TypeScript language,
manual-only approval and reject-all-busy-input defaults. They do not supersede its ownership,
context integrity, cancellation or no-retry requirements.

**Result:** the implemented backend additions align with those boundaries. This is a code
and automated-contract review, not certification of live provider behavior, native TCC
permission handling, remote deployment or hostile-filesystem containment. The Swift app
and its signing/Keychain configuration were not changed. There is no Swift capture adapter
yet; only the agreed backend capability protocol is implemented.

## Ownership check

| Owner | Implementation and evidence |
|---|---|
| Runner | `core/conversation.rs` is still the only inference/tool loop. It owns manual/automatic compaction, operation targeting, approvals, intent/resource checkpoints, pending-input checkpoints and cleanup. Manual compaction is an exclusive operation in the same lifecycle. |
| Manager | `manager.rs` owns catalog/configuration, frozen workspace instructions, account-attempt lifetime, asset/log references, native capability registration, fork/delete/release and persistence coordination. It never performs a second inference loop. |
| Providers | `providers/openai/`, `deepseek.rs` and `registry.rs` own authentication, concrete endpoints/models, request/stream decoding, account/search/image services, discovery caches and opaque context. Shared authentication carries no mutable conversation transcript/context. |
| Tools | Image generation and screenshot tools prepare exact actions without contacting a provider/frontend or creating assets. The runner authorizes/checkpoints before execution. Concrete tools return text plus typed neutral details in one execution. |
| API | `service.rs` validates/routes commands and transports snapshots/NDJSON, image bodies and correlated native messages. It does not decode provider context, choose tool execution, retry work, or run compaction independently. Service startup is the composition root. |
| Frontend | `client.rs`, `terminal.rs` and CLI code observe/control the same authoritative operations. They own browser launch, display reconciliation, input and explicit file-copy presentation. No client inference loop or independent transcript store was added. The future Swift adapter owns capture/TCC and native cleanup. |

The runtime has no imports of HTTP clients, HTTP servers, OpenAI/DeepSeek modules, OAuth
formats, encrypted-reasoning fields, native capture implementations or concrete asset files.
It uses `ChatProvider`, neutral message IDs, `ImageReader`, prepared tools and checkpoints.
Native window result types are neutral core DTOs, not a dependency from core into `native`.

## All guiding principles checked

1. **Own the runtime:** no agent framework, hosted harness or delegated tool loop.
2. **Keep it small:** one Rust crate/process, focused modules and existing Tokio/serde
   infrastructure. Added dependencies solve concrete requirements: RSA verification,
   base64 payloads and bounded PNG/JPEG validation. No plugin or distributed scaffolding.
3. **Separate responsibilities:** ownership table above; core can run without HTTP.
4. **One authority:** only the runner changes active operation/transcript state; manager
   mutations remain durable and exclusive. Browser attempts are manager-owned account work.
5. **Provider neutrality:** concrete image model choice is inside OpenAI, not the tool or
   frontend. The registry requires unambiguous image-provider composition and has no fallback.
6. **Explicit concurrency:** one active turn/compaction per conversation; independent
   conversations still run concurrently. Refresh is single-flight, not per-conversation.
7. **Execution-boundary approval:** image quota use and native requests follow the existing
   prepare/authorize/intent/execute/result path. Auto mode cannot enable desktop/TCC access.
8. **Precise targeting:** operation/approval IDs remain single-use. Native replies must match
   request, frontend, conversation, operation, call and action, plus kernel-attested peer PID.
9. **Cancellation cleanup:** the runner retains executors; detached refresh persists before
   provider shutdown settles. Native broker reservations are invalidated on cancellation,
   dropped requests, revoked permission or disconnect; the future adapter owns OS cleanup.
10. **No automatic replay/retry:** fixed-origin transports disable retries. Refresh persists
    a consumed-token marker before exchange. Uncertain refresh/checkpoint outcomes block work;
    uncertain optional cache writes disable further cache writes until restart.
11. **Truthful context:** final text replaces provisional deltas; only completed responses
    release calls/context/usage. OpenAI output is account-bound and checked against completed
    text/calls. Compaction never executes incidental calls or replaces visible history.
12. **Meaningful checkpoints:** uploads reserve durable ownership before file publication;
    generated/captured assets reserve references with intent before possible effects.
    Compaction state is checkpointed before another inference; terminal success still waits.
13. **Conservative recovery:** version 7 reads versions 1–6 conservatively. No restored turn,
    image generation, capture, token exchange, temp file or tool is resumed/promoted.
    Unreadable conversations keep unknown references conservatively retained.
14. **Distinct guarantees:** 202 means command acceptance, not durable completion. A native
    reply acknowledgement means correlation was accepted, not that a successful tool result
    or asset checkpoint has been published. Account observations include freshness.
15. **Safe reconnect:** ordinary observers detach without replay/cancellation. The native
    channel is an explicitly bound capability, not an ordinary observer: losing it revokes
    that capability and invalidates its exact pending requests, without rerouting them.
16. **Honest boundaries:** private UDS/JSON/assets, fixed provider origins, bounded streams,
    decoding/allocation/concurrent image validation, no raw secret diagnostics and clean
    shell environments. Same-user processes/filesystems are not a sandbox or multi-tenant API.
17. **Host-based execution:** capture requires explicit trusted host nomination, same-user
    process creation identity and kernel Unix peer PID. Frontend presence/self-asserted
    locality is insufficient. No headless/remote capture code or fallback exists.
18. **Verification honesty:** focused fake-transport/store/native tests cover auth rotation,
    cancellation, approval denial, context integrity, save failures, restart and fork ownership.
    They do not establish live OAuth, subscription quota or OS permission compatibility.

## Corrections made during the audit

- Removed concrete image-generation provider/model selection from tools; the provider
  contract exposes a neutral image service and composition rejects ambiguity.
- Added pending-input checkpointing while automatic compaction is awaiting the provider.
- Kept native OS permission separate from session permission; revoking/restoring OS access
  cannot implicitly re-enable a conversation. Registration is one-shot and checks PID reuse.
- Added cleanup guards for dropped native request futures and exact cancellation messages;
  acceptance of late results does not depend on best-effort message delivery.
- Bound provider-local as well as persisted model metadata to credential/account identity.
- Isolated optional cache failures and disabled uncertain cache writes rather than repeatedly
  attempting persistence or blocking unrelated conversation history.
- Preserved authoritative final text corrections in the terminal frontend rather than
  assuming that a completed response always extends the streamed prefix.

## Verification and remaining non-implementation checks

The delivery checks are `cargo fmt --check`, `cargo test --locked --all-targets`,
`cargo clippy --locked --all-targets -- -D warnings`, `cargo build --locked --release`,
`cargo test --locked --doc`, and `git diff --check`, run from `agent-rust/` (Git at this
repository root). Tests use isolated temporary stores and fake transports, never the user's
Keychain/credentials or live model calls. OpenSSL only generates ephemeral synthetic RSA test
fixtures. No private key, issued credential, authorization URL or account identifier is
committed or printed by application diagnostics.

Live OpenAI/DeepSeek compatibility, interactive browser sign-in, real subscription image
quota behavior, Swift/native TCC permission dialogs, Linux deployment and machine power-loss
behavior remain manual verification. No Swift code/signing changes were made, so the macOS
application build/signing steps are not part of this Rust-only change.

The approved implementation exclusions/deferrals remain unchanged: no remote access,
Keychain, Swift-store migration, frontend rewrite/capture adapter, generated titles or
per-run before/after allowance observations. None is hidden behind a claimed fallback.
