# Changelog

## Unreleased — 2026-10-12

- Remove only `com.apple.quarantine` from managed Wine bundles after consent, using native no-follow filesystem APIs; preserve other attributes and reject escaping paths.
- Reuse the existing installation confirmation for unsigned-runtime trust instead of adding a second prompt; the CLI requires `--accept-unsigned`, and the core API explicitly requires consent.
- Apply the same quarantine removal to cached Wine after validating its provenance receipt and layout, so previously blocked downloads can be reused without downloading the archive again.
- Add quarantine and consent regressions; verify real fresh/cached Wine execution and the native trust-install workflow.
- Show native Wine download progress with percentage, received/total size, and recent transfer speed; unknown-length downloads retain byte counts and speed without inventing a percentage.
- Stream downloads through a task-owning native delegate with throttled progress callbacks, ordered installation phases, cancellation cleanup, and no stale statistics after completion or failure.
- Add progress arithmetic and final-emission regressions; verify slow known-length/chunked downloads and live native Wine-install progress.
- Add per-bottle Standard / DXVK — Experimental selection; older bottles remain Standard without metadata rewrites.
- Bundle MagicWine's corrected native macOS DXVK 1.10.3-based component, with archive/payload SHA-256 and PE-architecture checks, immutable receipts, public-source build provenance, and zlib attribution. Preserve DXVK quarantine.
- Install only D3D10/11 DLLs in the selected prefix, retain original files/links/absence, recover interrupted changes, and preserve custom replacement DLLs when restoring Standard.
- Scope DLL overrides, optional version/API/GPU/FPS/frame-time HUD, shader cache, and diagnostics to the selected bottle; keep Wine's built-in DXGI and reject unavailable selected components instead of falling back silently.
- Stop the bottle before changing graphics; protect metadata-to-spawn handoff and live-process completion across app/CLI processes. HUD-only updates avoid reinstalling DLLs.
- Verify real 32/64-bit Direct3D 11 shader rendering and fullscreen/readback, C-drive launcher diagnostics, Standard Direct3D 9 switchback, interprocess stop/switch, and missing-component restoration. Add integrity, recovery, concurrency, and rejected-component-replacement regressions; 56 tests pass.
- Keep Direct3D 12 separate; do not bundle proprietary D3DMetal/GPTK or claim anti-cheat/game compatibility.
- Match CrossOver's unavailable-results behavior for unsupported pipeline-statistics queries: create the native query, preserve lifecycle validation, and return `S_FALSE` without fabricated counters or unsupported Vulkan allocations. This replaces the earlier strict rejection that crashed Tropics' D3D10 engine.
- Cross-compile a separately versioned 32/64-bit component from SHA-pinned public source with a checked-in patch and build recipe; install it offline from the app/CLI resource bundle.
- Remove the dedicated DXVK update UI and in-place component-replacement path after a user-reported failed update; retain fresh-bottle installation, current-component HUD changes, and Standard rollback. Older selections direct users to a new bottle without automatic migration or deletion.
- Preserve pinned redistribution notices for the static MinGW/GCC/Winpthreads runtimes and public headers in the resource bundle and installed DXVK receipt; include MagicWine's GPL license in packaged app/CLI output.
- Exercise native 32/64-bit query rejection and GPU readback, fresh-bottle native graphics enablement/rollback, legacy CLI rejection without side effects, and Tropics' DirectX 11 windowed shortcut through the corrected component. The user confirms Tropics works in a new bottle with very low FPS; do not claim a performance improvement.
- Ship `1.10.3-magicwine.2` for both architectures, with D3D10 adapter validation delegated to DXVK rather than WineD3D's unrelated capabilities.
- Use process-local WineD3D Vulkan initialization for DXVK launches, avoiding the built-in DXGI OpenGL/WoW64 crash without requiring the graphics HUD.
- Verify D3D10 GPU clear/readback and D3D11 shader draw/readback in 32/64-bit managed Wine, and compare query completion against an isolated CrossOver bottle; 62 Swift tests pass after full integration.
- Include native D3D9 in both architectures, with current-MinGW header compatibility and Vulkan feature requests gated by driver support. D3D9 no longer falls through to WineD3D when DXVK is selected.
- Verify Tropics' D3D9, D3D10, and D3D11 windowed demos reach world initialization without the HUD, plus native D3D9 triangle rendering/readback on both architectures.
- Preserve legacy four-DLL rollback and interrupted recovery while managing all six DLLs for new installations; retain pre-existing D3D9 files during legacy restoration. Exercise real legacy rollback, six-DLL enablement, and restoration without altering the saved D3D9 originals.
- Fix Tropics Demo v1.3 launcher startup on Apple Silicon with a public-source-built Wine 11.0 Rosetta CPU transition repair, scoped to SHA-verified stock runtimes and ordinary bottle-owned DLLs. Preserve and validate the original CPU, source archive, and LGPL notice before atomic replacement; leave shared runtimes and unknown builds untouched.
- Prefer the launcher's application-local `SHDocVw.dll` managed assembly over Wine's namesake DLL, with built-in fallback, while composing the CPU/browser overrides with the selected graphics backend.
- Verify the original saved Tropics launcher opens its settings window and embedded browser through the packaged CLI; 74 regression tests pass. Leave the separate Run-button scripting bug unchanged after reproducing it in both runtimes; game files remain unmodified.
- Port the redesigned dark wine-themed native interface: searchable bottle sidebar, adaptive dashboard cards, installed-program launchers, and Downloads, Settings, and Documentation pages.
- Bundle original interface artwork and the application icon alongside the current DXVK/Wine compatibility resources and redistribution notices; retain newer Direct3D 9/10/11 support, legacy-component guards, and per-bottle runtime/operation behavior.
- Support isolated native UI libraries through `MAGICWINE_DATA_ROOT` and optional development bundle names/identifiers without changing the default library.

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
