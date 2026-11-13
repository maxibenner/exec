# Swift → Rust integration work log

## Agreed scope
- Bundle and automatically launch the existing Rust service; do not change Rust.
- Fresh private backend profile; no import, deletion or alteration of legacy Swift data/Keychain.
- Keep existing native views, transcript rendering, confirmations, navigation and copy except minimally necessary compatibility corrections.
- Remove automatic session-title generation (explicit exception).
- Document wholly unsupported features; do not implement speculative substitutes or Swift backend fallbacks.

## Implementation record
- [x] Map API contracts onto existing presentation models and identify parity constraints.
- [x] Implement bounded network TCP HTTP/NDJSON transport, no mutation retries.
- [x] Bundle/sign helper, automatic startup, awaited shutdown and conservative crash handling.
- [x] Replace Swift inference/authentication/tools/persistence with backend-owned operations.
- [x] Connect sessions, settings, accounts, images, approval, cancellation and streaming.
- [x] Retain the original virtual transcript renderer and native views/local-only state.
- [x] Assess native screenshot integration: deferred permission-flow mismatch documented; no silent grant or fallback.
- [x] Remove obsolete implementation/tests, retain meaningful UI tests and add transport/integration tests.
- [x] Run tests and signed application build; document manual verification and gaps.

Repository finalization (focused Conventional Commit, merge to `main`, worktree/branch cleanup) follows verification. See Git history for the final commit.

## Confirmed contract constraints
- Rust settings/rename/model/fork require idle conversations. No live auto-mode mutation or active-turn fork.
- Steering currently takes text only, not images; manual compaction cannot be steered.
- Rust has no automatic session titles or per-run allowance observations.
- Provider statuses contain no account display name; credentials are private plaintext, not Keychain.
- Native capture requires prior OS permission plus separately enabled session capability. Existing one-shot screenshot approval is not itself a capability grant.
- Rust owns immutable workspace paths, root instruction freezing, image/log ownership and all checkpoint recovery.
- Compaction API exposes operation state, not the old transcript activity rows.

Final verification and unresolved decisions are recorded in `docs/swift-rust-migration.md`.

## Follow-up integration

- [x] Connect the HTTP native screenshot channel with explicit `/screenshots` session grants and native OS permission checks.
- [x] Queue idle-only slash commands; preserve exact approvals and cancellation. Keep `/workspace` inactive after the initial choice/start, but allow one change to a newly inherited folder.
- [x] Refresh allowance only on opening Settings; remove before/after observations from requirements.
- [x] Open browser authentication directly and remove onboarding auth/storage descriptions.
- [x] Diagnose/fix OpenAI streams with missing Content-Type and verify synthetic/live behavior.
- [x] Run authorized one-off live text, Unicode, context, steering, vision and image-generation checks, then clean up temporary conversations. No live fixtures were added to tests.

See the updated migration report for the verification boundaries and remaining manual TCC/UI checks.

## HTTP API review

- [x] Keep one HTTP dispatcher over the existing manager/runtime; no second API or agent loop.
- [x] Require bearer auth by default, restore loopback, permit explicit network binding and external-auth opt-out.
- [x] Separate native capability credentials from ordinary API access; preserve explicit grants/cancellation.
- [x] Align Swift owned/external connections, TLS, remote workspace paths and detach-only external shutdown.
- [x] Verify authenticated HTTP and no replay with isolated tests and one-off stored-provider smoke checks.

Configuration and deployment boundaries are documented in `docs/http-api-review.md`.
