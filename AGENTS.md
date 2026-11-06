# Exec project instructions

## Git

- This directory is its own Git repository. Run Git commands here, not in the parent workspace repository.
- Always use Conventional Commits: `type(scope): imperative summary` (scope optional).
- Examples: `feat(auth): add session recovery`, `fix(stream): cancel stalled responses`, `test: cover sign-out failures`.
- Make focused commits after verification. Never commit credentials, tokens, Keychain exports, `.build/`, or `dist/`.
- Do not rewrite existing commits or change the parent repository without explicit permission.

## Implementation

- Build things modular and as minimal as possible. Keep code readable, maintainable and understandable; prefer clear names and straightforward control flow.
- Reuse existing components and logic where it makes sense. Avoid duplication, but do not introduce abstractions or frameworks without a concrete need.
- Do not overengineer. Prefer practical solutions to current requirements over speculative features, elaborate architecture, or premature optimization.
- Keep the app native Swift. Avoid dependencies unless needed and approved.
- Keep clear module boundaries across core logic, providers, UI components, and any future plugins or skills so additions can be made without rewriting unrelated code.
- Design for straightforward extension through small, explicit interfaces and composition. Introduce plugin/skill infrastructure only when a concrete feature needs it—not speculative scaffolding.
- UI and orchestration depend on `ChatProvider`, not OpenAI wire formats.
- Provider-specific authentication, model discovery and opaque response context stay in `Providers/`.
- Keep credentials in Keychain. Never log tokens, authorization URLs, raw token responses or personal account identifiers.
- No automatic retries of inference or rotating-token exchanges; failures can occur after the server performed the operation.
- Preserve explicit cancellation and distinguish interrupted/failed turns from completed context.
- Use stable code signing when a certificate is available; never silently change signing identity or relax Keychain access controls.
- Do not write progress statuses or hints into the UI. E.g. "Chat only - no file or shell tools yet". The only exception is keyboard shortcut hints on sidebar items (e.g. ⌘1, ⌘2) showing their available navigation shortcuts. It is okay to use UI hints/descriptions if it is important context for evaluating the functionality of the feature.

## Verification

- Run `./scripts/test.sh` and `./scripts/build-app.sh` before committing code changes.
- Keep tests small, practical and focused on meaningful behavior and regressions. Prioritize authentication, cancellation, conversation integrity and error recovery; do not build an oversized suite, chase coverage percentages or test trivial implementation details.
- Tests must use isolated stores/fake transports, not the user's Keychain or live model calls.
- Report manual checks or signing steps that remain unverified; do not claim mocks verify live service behavior.
