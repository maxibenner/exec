# Retired lazy-transcript preview

The former `build-lazy-preview.sh` was an isolated experimental renderer, not the
production transcript. It depended on the removed Swift session/Keychain stores
and has been retired with the Rust integration. Do not use it to build Exec.

The production app retains `VirtualTranscript`, its native scroll/selection and
layout machinery, and the existing message views. Build with `./scripts/build-app.sh`.
`benchmark-transcript.sh` remains a synthetic comparative benchmark only; it does
not modify production sources or connect to a backend.

See `../../docs/swift-rust-migration.md` for migration boundaries and verification.
