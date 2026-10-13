# Changelog

## Unreleased — 2026-10-13

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
- Do not bundle proprietary D3DMetal/GPTK or claim anti-cheat/game compatibility.
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
- Add per-bottle DXMT and D3DMetal selections, experimental consent, Metal HUD controls, native library-folder import, and matching CLI/core APIs.
- Bundle the unchanged MIT-licensed DXMT v0.80 builtin release with pinned archive/payload hashes and native Wine/GPU capability checks; support 32/64-bit Direct3D 10/11 without modifying shared Wine.
- Import user-owned D3DMetal locally with content-addressed receipts, complete 64-bit Windows/Unix bridge validation, deployment-target checks, preserved notices/quarantine, and strict conventional-link validation. Never download, license, patch, or redistribute Apple's binaries.
- Select Metal builtins through verified private Wine runtime views, preserving original executable bytes/signatures and child-process loader identity. Resolve materialized Apple Unix aliases to one canonical shared image for correct framework lookup and shared dispatch state.
- Generalize transactional DLL backup/recovery across DXVK/DXMT/D3DMetal footprints while retaining legacy rollback. Direct backend switches and missing-component Standard restoration preserve original files, links, absent paths, and displaced user replacements.
- Reject stock managed Wine's incompatible Metal ABI before mutation; retain each bottle's pinned runtime and require explicit selection of a compatible native custom Wine loader.
- Verify real DXMT D3D10/11 rendering/readback in both architectures and D3DMetal D3D11/12 in 64-bit, repeated packaged launches, HUD-only preservation, direct Metal switches, missing-import rollback, unchanged original runtime hashes, and managed-Wine DXVK rendering. All 107 Swift regressions pass; rebuild and sign the app/CLI.
- Exercise the native four-backend picker, DXMT/D3DMetal consent, folder-only library import presentation, and cancellation back to the unchanged Standard selection; document compositor-capture limitations.
- Bind graphics consent to the selected backend and bottle rather than a separate DXVK-default state; preserve the selected backend through confirmation and show setup failures in a visible alert.
- Discover local D3DMetal libraries beside the bottle's selected Wine, then in user/system Applications CrossOver installations. Share discovery between app and CLI/core, retain explicit imports, and open the app's folder picker only when no source is found. Preserve existing library validation, license consent, quarantine, and pinned-Wine compatibility requirements.
- Verify native DXMT confirmation/persistence, cancellation, automatic D3DMetal import without a file panel, Standard rollback, and a visible compatibility error on unmodified upstream Wine without changing its DXVK selection. Exercise CLI import discovery and Windows execution, validate installed CrossOver libraries, pass all 109 regressions, and rebuild/sign the app and CLI.
- Replace the prerelease dual-runtime choice with one pinned Wine 11 installation containing MagicWine's source-built DXMT bridge. Remove the managed-distribution API and CLI flag; use preferred Wine automatically for bottle creation, with optional custom-runtime controls under Advanced.
- Stage the SHA-pinned driver with its real DXMT client-surface bridge, original-driver backup, LGPL license, complete corresponding source, and pinned-source build recipe. Keep its native image compressed during packaging; verify archive, driver, and source provenance before cached reuse. The base Wine archive downloads once; the driver bridge and DXMT require no additional download.
- Keep native Wine modules and DXMT's Unix bridge physically inside private graphics views so loader-relative dependencies cannot load a second original `ntdll`. Preserve Apple's canonical shared-library aliases and all original runtime bytes.
- Keep Standard graphics as the default and check host/GPU eligibility when enabling DXMT, not when installing Wine. Identify the managed DXMT-only ABI explicitly and reject D3DMetal without mutation; direct DXMT users to the single managed install.
- Keep the bundled DXMT component's immutable provenance independent of live onboarding text.
- Verify the single packaged Wine install, trust cancellation, cached reuse, automatic runtime selection, Standard-by-default bottle creation, and native DXMT confirmation. DXMT and DXVK both pass 32/64-bit D3D11 shader presentation/readback; restored Standard passes D3D9 triangle presentation/readback and Windows execution. Reject D3DMetal's incompatible ABI without metadata changes and reject the removed CLI flag. Retain custom-Wine DXMT/D3DMetal rendering and automatic import. All 117 regressions pass, including release resources; rebuild/sign app and CLI.
- Exclude obsolete managed Wine folders from discovery and remove the arbitrary first-runtime fallback. Resolve stale managed preferences to the current installed build, or show Wine setup before bottle creation when it is missing. Persist the resolved preference, preserve explicit external choices, and keep missing custom Wine from silently selecting another runtime. Clarify that the DXMT recovery path requires a new bottle after installing compatible Wine. All 119 release regressions pass.
- Exercise obsolete-preference recovery in the packaged app with current Wine both absent and already installed: native installation, preference persistence, new-bottle initialization, and DXMT confirmation succeed. Verify CLI discovery excludes old managed installs and that Windows execution succeeds with the corrected runtime; leave old driver bytes unchanged.

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
