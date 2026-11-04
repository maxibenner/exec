# Harness project instructions

## Git

- This directory is its own Git repository. Run Git commands here, not in the parent workspace repository.
- Always use Conventional Commits: `type(scope): imperative summary` (scope optional).
- Examples: `feat(auth): add session recovery`, `fix(stream): cancel stalled responses`, `test: cover sign-out failures`.
- Make focused commits after verification. Never commit credentials, tokens, Keychain exports, `.build/`, or `dist/`.
- Do not rewrite existing commits or change the parent repository without explicit permission.

## Implementation

- Build things modular and as minimal as possible. Keep code readable, maintainable and understandable; prefer clear names and straightforward control flow.
- Reuse existing components and logic where it makes sense. Avoid duplication, but do not introduce abstractions or frameworks without a concrete need.
- Keep the app native Swift. Avoid dependencies unless needed and approved.
- UI and orchestration depend on `ChatProvider`, not OpenAI wire formats.
- Provider-specific authentication, model discovery and opaque response context stay in `Providers/`.
- Keep credentials in Keychain. Never log tokens, authorization URLs, raw token responses or personal account identifiers.
- No automatic retries of inference or rotating-token exchanges; failures can occur after the server performed the operation.
- Preserve explicit cancellation and distinguish interrupted/failed turns from completed context.
- Use stable code signing when a certificate is available; never silently change signing identity or relax Keychain access controls.

## Verification

- Run `./scripts/test.sh` and `./scripts/build-app.sh` before committing code changes.
- Tests must use isolated stores/fake transports, not the user's Keychain or live model calls.
- Report manual checks or signing steps that remain unverified; do not claim mocks verify live service behavior.
