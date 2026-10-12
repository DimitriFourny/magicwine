# MagicWine

An open-source, native macOS app for installing and running Windows programs with Wine. Original SwiftUI interface and Swift runtime management; no Electron, background daemon, or bundled proprietary runtime.

## Build and launch

Requires macOS 14 or newer and Swift 6 developer tools. Install Apple's Command Line Tools with `xcode-select --install` if needed.

```sh
./scripts/build-app.sh
open dist/MagicWine.app
```

The script builds the native app for your Mac, creates an ad-hoc-signed development bundle, and also produces `dist/magicwine`, the command-line companion. Keep `dist/MagicWine_MagicWineCore.bundle` beside the CLI: it contains the pinned DXVK and Wine CPU compatibility resources. The app carries its own core bundle plus `MagicWine_MagicWine.bundle` for interface artwork in `Contents/Resources`, and its icon in `AppIcon.icns`. This is a local development build, not a notarized release. You can open `Package.swift` in Xcode instead.

**Preview toolchains:** the macOS 27 Command Line Tools installed during development omit the SwiftUI state macro plugin. The scripts use the complete installed macOS 26.5 SDK in that specific case; the resulting app still runs on macOS 27. Install complete Xcode tools if neither SDK is available. Set `MAGICWINE_SDK=/path/to/MacOSX.sdk` to select an SDK explicitly. No system developer settings are changed.

## Native interface

The dark wine-themed library has a searchable bottle sidebar and dedicated **Downloads**, **Settings**, and **Documentation** pages. Search filters bottle names, not installed programs. Select a bottle to open its dashboard: pinned runtime and status, installed-program launchers, installer and shortcut actions, graphics controls, logs, and confirmed Trash. Dashboard cards switch from two columns to one in narrower windows.

**Downloads** manages Wine installation and displays installed runtimes. **Settings** chooses the default for new bottles or an existing Wine executable; existing bottles retain their pinned runtime. The sidebar **+** button and **Command-N** open bottle creation. Native file pickers, installer URL handling, Wine trust confirmation, and bottle-specific busy/stop guards remain in place.

## First Windows application

1. Open MagicWine's **Downloads** page and choose **Install / Update Wine**, then **Trust and Install Wine**, or **Choose Wine Executable** for an existing installation.
2. Create a bottle. MagicWine initializes its own Windows environment with the selected Wine runtime.
3. Select **Install EXE/MSI** and choose the application's Windows installer. Complete the actual Windows installer normally.
4. Launch its discovered Start Menu shortcut. Use **Refresh Shortcuts** if necessary, or **Add Program** to select an EXE or LNK manually.

Managed Wine downloads show a progress bar, percentage, received/total size, and recent download speed. If the server does not supply a total size, the bar stays indeterminate while received bytes and speed still update. Release lookup, checksum verification, extraction, preparation, and runtime inspection have separate status messages. An already-installed runtime is reused without displaying a fictitious download.

**Stop** terminates the selected bottle's Windows processes, not other bottles. **Wine Configuration** opens Wine's settings. **Reveal C: Drive** opens the bottle's Windows files. Errors retain their operation logs; **Reveal Logs** makes them accessible.

Removing a program only removes its MagicWine launcher. Trashing a bottle stops its processes and moves its entire Windows environment to macOS Trash; external executables are not deleted. Failed initialization leaves a bottle available for **Retry Setup**.

## Wine and macOS requirements

Managed installation uses the maintained [Gcenx macOS Wine builds](https://github.com/Gcenx/macOS_Wine_builds), with the download URL and SHA-256 checksum from [Homebrew's Wine metadata](https://formulae.brew.sh/api/cask/wine-stable.json). Downloads are staged, checksum-verified, and installed privately without Homebrew or administrator access. A narrowly scoped per-bottle CPU compatibility repair is described below; it does not modify the downloaded runtime.

- **Unsigned distribution:** the current public Wine build is unsigned, and Homebrew flags it for Gatekeeper checks. The existing installation confirmation authorizes running unsigned Wine: MagicWine verifies the download checksum and removes only `com.apple.quarantine` inside its managed Wine bundle. This bypasses download-quarantine checks for that bundle, without changing system-wide security settings or custom Wine installations. Other extended attributes are preserved, and symbolic links are not followed. A checksum is integrity verification against metadata, not a publisher signature or malware assessment.
- **Apple Silicon:** Intel Wine requires [Rosetta](https://support.apple.com/102527). Install it yourself through Apple's prompt or `softwareupdate --install-rosetta`, reviewing Apple's license. MagicWine does not install Rosetta or accept the license.
- **Multimedia:** the inspected Wine 11.0_1 distribution's optional multimedia plugin needs the [GStreamer Universal runtime](https://gstreamer.freedesktop.org/download/), version 1.28.2 or newer, in `/Library/Frameworks/GStreamer.framework`. Basic Wine setup and ordinary programs do not require it. MagicWine does not install privileged system frameworks.
- Each bottle **pins its Wine executable**. Installing a newer managed runtime changes the default for new bottles, not existing bottles. Keep runtimes referenced by existing bottles installed. Custom executable paths must also remain available.
- **Already blocked managed Wine:** run **Install / Update Wine** again and accept **Trust and Install Wine**. When the latest runtime is already downloaded, MagicWine checks its provenance receipt and layout, removes its quarantine, and reuses it without downloading the archive again. Existing bottles are not deleted or migrated.

Wine compatibility varies by application. MagicWine offers an optional macOS DXVK backend below, but does not include CrossOver's application recipes, proprietary D3DMetal/GPTK components, or compatibility guarantees for DirectX games, DRM, or anti-cheat.

**A bottle is not a security sandbox.** Windows programs run with your macOS user's permissions, and Wine can expose host files through its drives. Only run software you trust. Logs may contain paths and application output; review them before sharing.

## Rosetta and legacy browser launchers

On Apple Silicon, the verified stock Wine 11.0 CPU transition code can crash while starting 32-bit .NET launchers under Rosetta. MagicWine bundles `wow64cpu-wine11.0-magicwine.1`, built from public Wine source with CodeWeavers' Rosetta far-call/far-return correction (CW HACK 20760). This fixes Tropics Demo v1.3's failure before its settings window appears; no CrossOver binary is used.

Before launching an initialized bottle, MagicWine checks the runtime version and original CPU DLL SHA-256, then atomically replaces only that bottle's known-stock `system32/wow64cpu.dll`. Its original DLL, corresponding source, and LGPL notice are preserved in `runtime-compatibility/wow64cpu-wine11.0-magicwine.1/`. Keep that backup intact. Custom prefix DLLs, links, corrupt resources, and missing or modified backups are rejected rather than overwritten; unknown runtime builds are left untouched. The process-local `wow64cpu=n` override is independent of DXVK and its HUD. Shared Wine files and bottle metadata are unchanged.

Launches also prefer application-provided `SHDocVw.dll` with `shdocvw=n,b`, retaining Wine's built-in fallback. This prevents Wine's namesake browser DLL from replacing the managed interop assembly shipped with older .NET launchers.

Rebuild with `brew install mingw-w64 python` and `bash scripts/build-wow64cpu.sh`. The recipe verifies pinned Wine and public CodeWeavers source, applies `patches/wine-wow64cpu-rosetta.patch`, and retains tool/source/command provenance under `.local/wow64cpu-magicwine-build.*/`. The bundled `wow64cpu-wine11.0-magicwine.1-source.tar.gz` contains the complete inputs and recipe for rebuilding offline with those tools. Update the independent resource pins in `RosettaCPUCompatibility.swift` when rebuilding with a different toolchain.

The original Tropics settings window and browser controls were exercised through the packaged saved shortcut. Its **Run** button has a separate `forms.settings` scripting failure reproduced in both MagicWine and the isolated CrossOver reference; it is intentionally unchanged, as are the game's files. Use the working DirectX demo shortcuts to start the game.

## Graphics and game testing

Every bottle defaults to **Standard**, including bottles saved by older MagicWine versions. Loading existing metadata does not rewrite it or change the bottle's Windows files.

- **Standard:** Wine's built-in graphics; OpenGL and Direct3D support depend on the pinned Wine runtime.
- **DXVK — Experimental:** optional Direct3D 9/10/11 translation through Vulkan/MoltenVK, using MagicWine's corrected build of the older [Gcenx macOS DXVK fork](https://github.com/Gcenx/DXVK-macOS/tree/8f1e28deed3ad30802f7e1bdff428ec14e6e7817). This is not current upstream DXVK. Direct3D 12 remains a separate development milestone.

Select an initialized bottle, choose **DXVK — Experimental** in **Graphics**, and accept its third-party/experimental warning. Setup stops only this bottle, verifies and installs the bundled package without a graphics download, and saves the new selection only after success. The Wine runtime must include the supported Vulkan/MoltenVK layout; MagicWine's managed Wine provides it.

The component is pinned to `1.10.3-magicwine.2` with archive SHA-256 `c06d15ed8bde38bc9fa9c22d8cb823a6904cc0d48fb967f3b43dd55b575458f7`. Archive layout, native 32/64-bit DLL architecture, individual payload hashes, and provenance are checked before use. A checksum is not a publisher signature or malware verification. No DXVK quarantine attributes or global Wine files are modified.

This build matches CrossOver's observed compatibility behavior for unsupported pipeline-statistics queries: creation succeeds, but `GetData` returns `S_FALSE` (results unavailable), without writing counters or allocating an unsupported Vulkan query pool. Query lifecycle validation is preserved, and drivers with real counter support retain it. This avoids Tropics' D3D10 null dereference after a rejected query; applications that wait indefinitely for statistics may still stall. No CrossOver binaries or proprietary components are included. D3D10 device creation lets DXVK validate the requested adapter and feature level instead of rejecting it based on WineD3D's unrelated capabilities.

Existing bottles are not automatically migrated, and direct in-place DXVK component replacement is not supported. To adopt the current component in an existing bottle, first choose **Standard** to restore its original graphics files, then enable **DXVK — Experimental** again. This retains the installed applications and launchers; game compatibility still requires testing. A new bottle remains an option for an isolated installation. Existing bottles and programs are never deleted automatically.

Only native `d3d9.dll`, `d3d10core.dll`, and `d3d11.dll` are installed in the selected prefix's `system32`/`syswow64`; Wine's built-in DXGI stays selected. **Standard** restores the original files, symbolic links, or absence without another download, even if the shared DXVK package is missing. User-modified replacement DLLs are retained in the bottle's `graphics/recovered/` directory instead of silently discarded. Keep the bottle's graphics backups intact.

DXVK launches set process-local `WINE_D3D_CONFIG=renderer=vulkan` so built-in DXGI enumerates its WineD3D adapter without entering the OpenGL/WoW64 initialization path that crashed Tropics before DXVK device creation. Standard launches do not receive this setting, and no registry or global runtime setting is changed. Native D3D9 requests geometry-shader/cull-distance features only when the Vulkan driver supports them; operations that require unavailable GPU features remain driver-limited.

Tropics' separate OpenGL launcher still requires `GL_ARB_map_buffer_range`, which the managed runtime's macOS OpenGL 2.1 compatibility context does not expose. DXVK does not translate OpenGL; use its DirectX launchers for this game. Verification of this release covers windowed D3D9/10/11 startup through world initialization and native 32/64-bit GPU readback, not long gameplay, fullscreen transitions, or performance.

**Show Graphics HUD** is optional, not a launch workaround. Enable it to identify DXVK/API/GPU and inspect FPS/frame times. Changes, including HUD updates, stop the bottle's Windows processes; controls are disabled during its active MagicWine operation. Start with an **offline Direct3D 9/10/11 game**, preferably one with a windowed mode. Check menus, gameplay, textures, fullscreen/windowed transitions, and stutter for 10–15 minutes. Anti-cheat/DRM and general game compatibility are not guaranteed; do not use this experimental backend to bypass anti-cheat.

Errors do not silently fall back to Standard. Use **Reveal Logs** for the Wine operation; DXVK logs are in `Logs/<bottle-UUID>-dxvk/`. If the managed component was manually changed, restore Standard first, move the affected version directory out of `Components/`, then enable DXVK again to reinstall the bundled pinned package.

To rebuild the maintained component, install `brew install mingw-w64 meson ninja glslang python`, then run `bash scripts/build-dxvk.sh`. The script verifies the source archive for commit `8f1e28deed3ad30802f7e1bdff428ec14e6e7817`, applies `patches/dxvk-pipeline-statistics.patch`, `patches/dxvk-d3d10-device.patch`, and `patches/dxvk-d3d9-macos.patch`, and cross-compiles both native architectures. It prints actual archive/payload hashes and retains compiler versions, build options, source/patch hashes, and logs under `.local/dxvk-magicwine-build.*/`. Update the independently pinned hashes and build-tool provenance in `DXVKInstallation.swift` before distributing any rebuilt archive; compiler changes can change the binaries. Preserve or update dependency notices and their separate checksum for the actual linked runtimes. A new component release requires a new version/ID and resource filename.

## Command-line companion

```sh
./dist/magicwine --help
./dist/magicwine runtimes
./dist/magicwine create "Windows Apps" "/path/to/wine"
./dist/magicwine list
```

Use the bottle and program UUIDs printed by `list` and `apps` for subsequent commands. `install`, `add`, `refresh`, `launch`, `stop`, and `configure` use the same runtime and storage as the desktop app. `exec` invokes Wine with the bottle's environment and preserves each argument without shell interpolation.

`--root /path/to/data` isolates CLI development data. The CLI managed-download command requires explicit consent: `install-wine --accept-unsigned`. This authorizes unsigned Wine and scoped quarantine removal, including reuse of an existing managed runtime.

Graphics commands use the same reversible setup:

```sh
./dist/magicwine graphics <bottle-UUID>
./dist/magicwine graphics <bottle-UUID> dxvk --accept-experimental --hud
./dist/magicwine graphics <bottle-UUID> dxvk --accept-experimental --no-hud
./dist/magicwine graphics <bottle-UUID> standard
```

Core clients use `WineRuntime.configureGraphics(_:in:showHUD:acceptExperimental:progress:)`; DXVK requires explicit `acceptExperimental: true`. `BottleStore.save` rejects direct or stale graphics changes. Launch/setup gates also protect against another MagicWine CLI process replacing DLLs during a launch.

## Data and development

Data lives in `~/Library/Application Support/MagicWine/`:

- `Bottles/<UUID>/bottle.json`: atomically saved metadata and launchers.
- `Bottles/<UUID>/prefix/`: Wine prefix and Windows filesystem.
- `Bottles/<UUID>/graphics/`: original-DLL backups, interrupted-change recovery, retained custom replacements, and per-bottle DXVK shader cache.
- `Bottles/<UUID>/runtime-compatibility/`: verified original Wine CPU DLL, corresponding repair source, and LGPL notice.
- `Bottles/.graphics-locks/`: storage and launch/lifetime locks shared by the app and CLI.
- `Runtimes/`: immutable, version/checksum-specific managed Wine installations with provenance receipts.
- `Components/`: immutable DXVK version/checksum-specific packages, verified receipts, and zlib attribution.
- `Logs/`: file-backed process and installation logs; no output-buffer growth while Windows apps run.
- `settings.json`: default and custom Wine selections.

`Sources/MagicWineCore` owns persistence, subprocess lifecycle, runtime discovery, and managed installation. `Sources/MagicWine` owns native UI state and views. `Sources/MagicWineCLI` is the command-line client. Subprocesses wait asynchronously; each bottle has separate UI activity, so another bottle remains usable.

For an isolated native-app library, launch the executable with `MAGICWINE_DATA_ROOT`:

```sh
MAGICWINE_DATA_ROOT="$PWD/.local/ui-smoke" ./dist/MagicWine.app/Contents/MacOS/MagicWine
```

The app and CLI can share this directory by passing the same path to CLI `--root`. Leave the variable unset for the normal library. For a separately named development bundle, `scripts/build-app.sh` accepts `MAGICWINE_APP_NAME` and `MAGICWINE_BUNDLE_ID`; both default to the normal MagicWine identity when unset.

Run deterministic storage regressions with:

```sh
./scripts/test.sh
```

The test script uses the installed Swift Testing plugin and disables XCTest, which is not shipped with this Command Line Tools installation. Real Wine workflow verification is separate from these tests; Wine is not downloaded during the test suite.

## Exercised verification

Development checks on Apple Silicon with macOS 27, Rosetta, and public Wine 11.0:

- Seventy-four regression tests pass across storage, quarantine/consent, download progress, DXVK integrity/architecture, reversible prefix changes/recovery, rejection of in-place component replacement, displaced user-DLL preservation, graphics concurrency boundaries, and safe Wine CPU repair/backup handling.
- Two real prefixes keep Windows files separate. Real 7-Zip 26.04 EXE and MSI installations create and validate archives.
- Saved EXEs and installed LNK shortcuts launch real Windows processes. Stop, repeated idle stop, timeout, and task cancellation leave the runtime usable.
- The native app launches and its model runs a Windows GUI program through the running → stop → idle transition without displaying a failure for a requested stop.
- The redesigned packaged app renders its welcome, Downloads, Settings, Documentation, and bottle dashboard with bundled artwork. App-local mouse/key events exercise navigation, no-match/clear bottle search, and bottle-creation presentation. Resizing to 1000 pixels switches the dashboard to one column. Its Launch and Stop buttons run real 7-Zip through busy → ready, restore enabled controls without an operation error, and leave no live bottle Wine server.
- The EXE/MSI installer and Wine configuration entry points open their actual Windows processes, and bottle Stop terminates them.
- Moving a bottle to macOS Trash leaves its externally registered executable unchanged.
- Managed Wine downloads pass checksum/extraction/provenance checks. The native trust confirmation starts a real fresh installation and saves its runtime preference; Wine reports `wine-11.0`. Reinstalling the previously quarantined cached runtime removes its quarantine and also passes Wine version inspection without downloading the archive again.
- Throttled real HTTP transfers with known and unknown sizes emit intermediate byte counts and measured speeds, preserve the complete payload, and propagate cancellation and interrupted connections. The native progress view receives live actual-Wine download updates; success, cached reuse, and a failed provenance check clear download statistics correctly.
- Real native 32-bit and 64-bit Direct3D 11 probes compile vertex/pixel shaders, render a colored triangle, present 90 frames, enter/leave fullscreen inside an isolated Wine desktop, and verify GPU readback. Logs identify `DXVK v1.10.3-20230507-async (macOS)`, MoltenVK 1.4.1, and Direct3D feature level 11.0. A registered EXE inside C: also renders and records its DXVK cache/logs.
- Switching the same isolated bottle back to Standard restores Wine's original DLLs and passes a real Direct3D 9 triangle/presentation/GPU-readback check using Wine's OpenGL backend. The Standard Direct3D 11 probe could not create a feature-level-10+ device on this setup; no general Standard D3D11 compatibility is claimed.
- A separate CLI process runs a real long-lived Direct3D program while the core switches its bottle to Standard: the program exits, the four original DLL hashes are restored, and unrelated DXGI/D3D9 files and saved programs stay unchanged. Removing the selected component blocks launch without fallback; Standard restoration still succeeds with the component absent.
- The corrected native 32-bit and 64-bit components reject unsupported pipeline-statistics queries through both `CreateQuery` and `CreateQuery1`, including validation-only calls, while supported event queries complete and GPU readback returns the requested RGBA color. The 32-bit probe uses an explicit adapter; its earlier implicit-adapter setup faulted before reaching the query checks.
- The earlier isolated Tropics **Demo DirectX 11 windowed** smoke selected `DXVK 1.10.3-magicwine.1`, reached feature level 11.0, loaded `tropics.world`, and continued beyond scene release without the query-pool assertion. Its `post_blur_radial` texture warning remained. The user subsequently reported that updating the original bottle still failed, while reinstalling in a new bottle worked with very low FPS. The update feature was removed; these observations do not establish a performance improvement or general rendering correctness.
- A real fresh Wine bottle enables the corrected bundled component and HUD through the native application model, then restores Standard. In-process images show the fresh selection and legacy recreation guidance without an update button. A packaged CLI request to replace a legacy component is rejected before Wine execution without changing DLLs, metadata, or backups; Standard still restores the exact original files/links.

Native views were captured in-process, and the fresh-bottle enable/HUD/rollback scenario uses the real application model and Wine processes. Full compositor screenshots and system-wide mouse/keyboard automation were unavailable without Screen Recording and Accessibility permissions; some layer-backed controls are incomplete in the in-process snapshots. Interactive installer completion still requires the normal Windows installer UI. These checks do not establish general Windows-application or game compatibility.

## License and references

MagicWine's original code is **GPL-3.0-or-later**; see [LICENSE](LICENSE). The full Wine distribution is downloaded separately and retains its own licenses and notices. The bundled Wine CPU repair is LGPL-2.1-or-later; `LICENSE-WINE-WOW64CPU.txt` preserves its attribution and license, and its complete corresponding source archive accompanies the DLL in the app/CLI resources and bottle backup. DXVK and the altered macOS fork use the zlib/libpng license. Installed DXVK packages carry both attributions and source/provenance links; `LICENSE-DXVK-DEPENDENCIES.txt` preserves their dependency notices. No proprietary graphics runtime is bundled.

Whisky and CrossOver supplied in `references/` informed workflow and dependency research. Reference application binaries and assets are not redistributed. The Wine CPU correction comes from the [public LGPL CodeWeavers source mirror](https://github.com/rnowak/wine-crossover-sources/blob/b4f3c510a1808e6e32fb99e9bc11fa46ccc207dc/wine/dlls/wow64cpu/cpu.c), not an extracted CrossOver binary. `references/`, build output, and local verification downloads are ignored by Git. CrossOver and Whisky are independent projects, not affiliations or endorsements.
