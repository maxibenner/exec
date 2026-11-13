# Swift → Rust integration work log

## Agreed scope
- Bundle and automatically launch the existing Rust service; do not change Rust.
- Fresh private backend profile; no import, deletion or alteration of legacy Swift data/Keychain.
- Keep existing native views, transcript rendering, confirmations, navigation and copy except minimally necessary compatibility corrections.
- Remove automatic session-title generation (explicit exception).
- Document wholly unsupported features; do not implement speculative substitutes or Swift backend fallbacks.

## Implementation record
- [x] Map API contracts onto existing presentation models and identify parity constraints.
- [x] Implement bounded Unix-socket HTTP/NDJSON transport, no mutation retries.
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
