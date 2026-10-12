# Changelog

## Unreleased — 2026-10-12

- Remove only `com.apple.quarantine` from managed Wine bundles after consent, using native no-follow filesystem APIs; preserve other attributes and reject escaping paths.
- Reuse the existing installation confirmation for unsigned-runtime trust instead of adding a second prompt; the CLI requires `--accept-unsigned`, and the core API explicitly requires consent.
- Apply the same quarantine removal to cached Wine after validating its provenance receipt and layout, so previously blocked downloads can be reused without downloading the archive again.
- Add quarantine and consent regressions; verify real fresh/cached Wine execution and the native trust-install workflow.
- Show native Wine download progress with percentage, received/total size, and recent transfer speed; unknown-length downloads retain byte counts and speed without inventing a percentage.
- Stream downloads through a task-owning native delegate with throttled progress callbacks, ordered installation phases, cancellation cleanup, and no stale statistics after completion or failure.
- Add progress arithmetic and final-emission regressions; verify slow known-length/chunked downloads and live native Wine-install progress.

## 0.1.0 — 2026-10-11

- Native macOS bottle library with Wine onboarding and persisted runtime preferences.
- Checksum-verified managed public Wine downloads, explicit unsigned-build consent, preserved quarantine, and per-bottle runtime pinning.
- Independent Windows environments, EXE/MSI installers, Start Menu/Desktop shortcut discovery, saved EXE/LNK launchers, and Wine configuration.
- Bottle-specific stop controls, bounded setup/probe operations, cancellable subprocesses, file-backed logs, and retryable bottle setup.
- Launcher removal without executable deletion; confirmed bottle removal through macOS Trash after stopping Windows processes.
- Shared command-line companion, local ad-hoc-signed app packaging, and storage regressions for persistence, path isolation, stale registrations, and shortcut traversal.
- Preserve exact metadata timestamps; distinguish requested stops from failures and verify the Wine server has exited before Trash.
- Track shortcut launches through the bottle's Wine server instead of relying on `start /wait` shortcut process handles.
- Report unsigned-runtime inspection timeouts with the executable path, macOS approval guidance, and the operation log.
- GPL-3.0-or-later original code; reference applications and downloaded runtimes excluded from Git.
