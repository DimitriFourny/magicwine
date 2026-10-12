# MagicWine

An open-source, native macOS app for installing and running Windows programs with Wine. Original SwiftUI interface and Swift runtime management; no Electron, background daemon, or bundled proprietary runtime.

## Build and launch

Requires macOS 14 or newer and Swift 6 developer tools. Install Apple's Command Line Tools with `xcode-select --install` if needed.

```sh
./scripts/build-app.sh
open dist/MagicWine.app
```

The script builds the native app for your Mac, creates an ad-hoc-signed development bundle, and also produces `dist/magicwine`, the command-line companion. Keep `dist/MagicWine_MagicWineCore.bundle` beside the CLI: it contains the pinned DXVK, DXMT, and Wine CPU compatibility resources. The app carries its own core bundle plus `MagicWine_MagicWine.bundle` for interface artwork in `Contents/Resources`, and its icon in `AppIcon.icns`. This is a local development build, not a notarized release. You can open `Package.swift` in Xcode instead.

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

Wine compatibility varies by application. MagicWine offers optional DXVK, DXMT, and locally imported D3DMetal backends below. It does not bundle CrossOver's application recipes or proprietary D3DMetal/GPTK components, or guarantee compatibility with DirectX games, DRM, or anti-cheat.

**A bottle is not a security sandbox.** Windows programs run with your macOS user's permissions, and Wine can expose host files through its drives. Only run software you trust. Logs may contain paths and application output; review them before sharing.

## Rosetta and legacy browser launchers

On Apple Silicon, the verified stock Wine 11.0 CPU transition code can crash while starting 32-bit .NET launchers under Rosetta. MagicWine bundles `wow64cpu-wine11.0-magicwine.1`, built from public Wine source with CodeWeavers' Rosetta far-call/far-return correction (CW HACK 20760). This fixes Tropics Demo v1.3's failure before its settings window appears; no CrossOver binary is used.

Before launching an initialized bottle, MagicWine checks the runtime version and original CPU DLL SHA-256, then atomically replaces only that bottle's known-stock `system32/wow64cpu.dll`. Its original DLL, corresponding source, and LGPL notice are preserved in `runtime-compatibility/wow64cpu-wine11.0-magicwine.1/`. Keep that backup intact. Custom prefix DLLs, links, corrupt resources, and missing or modified backups are rejected rather than overwritten; unknown runtime builds are left untouched. The process-local `wow64cpu=n` override is independent of DXVK and its HUD. Shared Wine files and bottle metadata are unchanged.

Launches also prefer application-provided `SHDocVw.dll` with `shdocvw=n,b`, retaining Wine's built-in fallback. This prevents Wine's namesake browser DLL from replacing the managed interop assembly shipped with older .NET launchers.

Rebuild with `brew install mingw-w64 python` and `bash scripts/build-wow64cpu.sh`. The recipe verifies pinned Wine and public CodeWeavers source, applies `patches/wine-wow64cpu-rosetta.patch`, and retains tool/source/command provenance under `.local/wow64cpu-magicwine-build.*/`. The bundled `wow64cpu-wine11.0-magicwine.1-source.tar.gz` contains the complete inputs and recipe for rebuilding offline with those tools. Update the independent resource pins in `RosettaCPUCompatibility.swift` when rebuilding with a different toolchain.

The original Tropics settings window and browser controls were exercised through the packaged saved shortcut. Its **Run** button has a separate `forms.settings` scripting failure reproduced in both MagicWine and the isolated CrossOver reference; it is intentionally unchanged, as are the game's files. Use the working DirectX demo shortcuts to start the game.

## Graphics and game testing

Every bottle defaults to **Standard**, including bottles saved by older MagicWine versions. Loading existing metadata does not rewrite it or change the bottle's Windows files.

| Backend | Translation provided | Component and requirements |
| --- | --- | --- |
| Standard | Wine's built-in graphics | Depends on the bottle's pinned Wine runtime |
| DXVK — Experimental | 32/64-bit Direct3D 9/10/11 → Vulkan/MoltenVK | Bundled macOS fork; supported by managed Wine |
| DXMT — Experimental | 32/64-bit Direct3D 10/11 → Metal | Bundled DXMT v0.80; Apple Silicon, macOS 15+, compatible native Wine |
| D3DMetal — Experimental | 64-bit Direct3D 11/12 → Metal | User-imported Apple libraries; Apple Silicon, macOS 14+ or the library's higher minimum, compatible native Wine |

Select an initialized bottle and choose a backend in **Graphics**. Nonstandard backends require experimental/third-party consent. Setup validates compatibility, stops only this bottle, and saves the selection after successful installation. Direct backend switches preserve the complete original DLL set, including different 32/64-bit footprints. **Standard** restores original files, links, or absence even if the selected component is missing; displaced user replacements go to `graphics/recovered/`. Keep these backups intact. Errors do not silently select another backend.

### DXVK

DXVK uses MagicWine's corrected build of the older [Gcenx macOS fork](https://github.com/Gcenx/DXVK-macOS/tree/8f1e28deed3ad30802f7e1bdff428ec14e6e7817), not current upstream DXVK. It does not implement Direct3D 12. Setup verifies and installs the bundled package without a graphics download. The Wine runtime must include the supported Vulkan/MoltenVK layout; MagicWine's managed Wine provides it.

The component is pinned to `1.10.3-magicwine.2` with archive SHA-256 `c06d15ed8bde38bc9fa9c22d8cb823a6904cc0d48fb967f3b43dd55b575458f7`. Archive layout, native 32/64-bit DLL architecture, individual payload hashes, and provenance are checked before use. A checksum is not a publisher signature or malware verification. No DXVK quarantine attributes or global Wine files are modified.

This build matches CrossOver's observed compatibility behavior for unsupported pipeline-statistics queries: creation succeeds, but `GetData` returns `S_FALSE` (results unavailable), without writing counters or allocating an unsupported Vulkan query pool. Query lifecycle validation is preserved, and drivers with real counter support retain it. This avoids Tropics' D3D10 null dereference after a rejected query; applications that wait indefinitely for statistics may still stall. No CrossOver binaries or proprietary components are included. D3D10 device creation lets DXVK validate the requested adapter and feature level instead of rejecting it based on WineD3D's unrelated capabilities.

Existing bottles are not automatically migrated, and direct in-place DXVK component replacement is not supported. To adopt the current component in an existing bottle, first choose **Standard** to restore its original graphics files, then enable **DXVK — Experimental** again. This retains the installed applications and launchers; game compatibility still requires testing. A new bottle remains an option for an isolated installation. Existing bottles and programs are never deleted automatically.

Only native `d3d9.dll`, `d3d10core.dll`, and `d3d11.dll` are installed in the selected prefix's `system32`/`syswow64`; Wine's built-in DXGI stays selected. **Standard** restores the original files, symbolic links, or absence without another download, even if the shared DXVK package is missing. User-modified replacement DLLs are retained in the bottle's `graphics/recovered/` directory instead of silently discarded. Keep the bottle's graphics backups intact.

DXVK launches set process-local `WINE_D3D_CONFIG=renderer=vulkan` so built-in DXGI enumerates its WineD3D adapter without entering the OpenGL/WoW64 initialization path that crashed Tropics before DXVK device creation. Standard launches do not receive this setting, and no registry or global runtime setting is changed. Native D3D9 requests geometry-shader/cull-distance features only when the Vulkan driver supports them; operations that require unavailable GPU features remain driver-limited.

Tropics' separate OpenGL launcher still requires `GL_ARB_map_buffer_range`, which the managed runtime's macOS OpenGL 2.1 compatibility context does not expose. DXVK does not translate OpenGL; use its DirectX launchers for this game. Verification of this release covers windowed D3D9/10/11 startup through world initialization and native 32/64-bit GPU readback, not long gameplay, fullscreen transitions, or performance.

**Show Graphics HUD** is optional, not a launch workaround. Enable it to identify DXVK/API/GPU and inspect FPS/frame times. Changes, including HUD updates, stop the bottle's Windows processes; controls are disabled during its active MagicWine operation. Start with an **offline Direct3D 9/10/11 game**, preferably one with a windowed mode. Check menus, gameplay, textures, fullscreen/windowed transitions, and stutter for 10–15 minutes. Anti-cheat/DRM and general game compatibility are not guaranteed; do not use this experimental backend to bypass anti-cheat.

Errors do not silently fall back to Standard. Use **Reveal Logs** for the Wine operation; DXVK logs are in `Logs/<bottle-UUID>-dxvk/`. If the managed component was manually changed, restore Standard first, move the affected version directory out of `Components/`, then enable DXVK again to reinstall the bundled pinned package.

To rebuild the maintained component, install `brew install mingw-w64 meson ninja glslang python`, then run `bash scripts/build-dxvk.sh`. The script verifies the source archive for commit `8f1e28deed3ad30802f7e1bdff428ec14e6e7817`, applies `patches/dxvk-pipeline-statistics.patch`, `patches/dxvk-d3d10-device.patch`, and `patches/dxvk-d3d9-macos.patch`, and cross-compiles both native architectures. It prints actual archive/payload hashes and retains compiler versions, build options, source/patch hashes, and logs under `.local/dxvk-magicwine-build.*/`. Update the independently pinned hashes and build-tool provenance in `DXVKInstallation.swift` before distributing any rebuilt archive; compiler changes can change the binaries. Preserve or update dependency notices and their separate checksum for the actual linked runtimes. A new component release requires a new version/ID and resource filename.

### DXMT and D3DMetal

**Managed Wine Stable 11.0 does not provide the native driver ABI required by either Metal backend.** MagicWine rejects that combination before stopping the bottle or changing its files. In Settings, explicitly select a compatible native `wine`/`wineloader` executable from a DXMT/GPTK-capable Wine distribution, then create and initialize a bottle with it. Do not choose a shell/Perl wrapper that changes `WINEPREFIX` or DLL selection. Existing bottles retain their pinned Wine; selecting graphics does not migrate a prefix or patch a shared runtime.

DXMT installs the unchanged [v0.80 builtin release](https://github.com/3Shain/dxmt/releases/tag/v0.80) offline. Its archive SHA-256 is `8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`; the managed identifier is `dxmt-v0.80`. It checks the Apple GPU family, native Wine exports, archive layout, PE/Mach-O architecture, and pinned payload hashes. It selects `d3d10core`, `d3d11`, `dxgi`, and `winemetal` for both Windows architectures, plus the native Metal bridge. It does not replace Direct3D 9 or 12. See the [upstream installation guide](https://github.com/3Shain/dxmt/wiki/DXMT-Installation-Guide-for-Geeks) for compatible Wine requirements.

D3DMetal is **local import only**. Obtain the libraries yourself under the applicable [Apple Game Porting Toolkit terms](https://developer.apple.com/games/game-porting-toolkit/). Choosing D3DMetal opens **Choose Libraries…**; select an extracted evaluation-environment folder containing `redist/lib`, that `lib` folder, or a compatible `apple_gptk` root containing `external/` and `wine/`. A framework alone is insufficient: the matching 64-bit Windows DLLs, Unix shared-bridge aliases, `libd3dshared.dylib`, framework resources, and dependency notices are required. Conventional framework/shared-library links and byte-identical materialized aliases are supported; escaping links and mismatched bridge versions are rejected.

MagicWine does not download Apple libraries, accept Apple's agreement, modify their bytes, re-sign them, or remove their quarantine. It copies and verifies the selected payload into a content-addressed `d3dmetal-<SHA-256>` component and preserves accompanying notices. A configured bottle can launch and change its HUD without the original source folder. Switching another backend to D3DMetal requires selecting the source again; an identical import reuses its verified component. To replace a component version, restore Standard first, then enable the new component.

Wine searches its native runtime directory before `WINEDLLPATH`. Metal launches therefore use a private, verified runtime view under `Runtimes/.graphics-views/`: unchanged copies of the native loaders/`ntdll`, links to the original runtime, and selected graphics overlays. Apple's Unix aliases resolve to one canonical shared image, preserving native global state and framework lookup without `DYLD_*` overrides. Original Wine and imported-library bytes remain unchanged, including signatures. Keep the selected custom Wine installation available.

**Show Graphics HUD** enables Apple's Metal HUD for DXMT/D3DMetal. HUD-only changes stop the bottle but do not reinstall its DLLs. DXMT logs go to `Logs/<bottle-UUID>-dxmt/`, with its shader cache in the bottle's `graphics/dxmt-cache/`; D3DMetal diagnostics use the Wine operation log. All launch overrides are process-local. Neither Metal backend translates OpenGL, and no general game, anti-cheat, fullscreen, or performance guarantee is implied.

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
./dist/magicwine graphics <bottle-UUID> dxmt --accept-experimental --hud
./dist/magicwine graphics <bottle-UUID> d3dmetal --accept-experimental --import "/path/to/redist/lib"
./dist/magicwine graphics <bottle-UUID> d3dmetal --accept-experimental --no-hud
./dist/magicwine graphics <bottle-UUID> standard
```

Core clients use `WineRuntime.configureGraphics(_:in:showHUD:acceptExperimental:componentSource:progress:)`; every nonstandard backend requires `acceptExperimental: true`. Pass `componentSource` when selecting/importing D3DMetal; it is not accepted for other backends. `BottleStore.save` rejects direct or stale graphics changes. Launch/setup gates also protect against another MagicWine CLI process replacing DLLs during a launch.

## Data and development

Data lives in `~/Library/Application Support/MagicWine/`:

- `Bottles/<UUID>/bottle.json`: atomically saved metadata and launchers.
- `Bottles/<UUID>/prefix/`: Wine prefix and Windows filesystem.
- `Bottles/<UUID>/graphics/`: original-DLL backups, interrupted-change recovery, retained custom replacements, and per-bottle DXVK/DXMT shader caches.
- `Bottles/<UUID>/runtime-compatibility/`: verified original Wine CPU DLL, corresponding repair source, and LGPL notice.
- `Bottles/.graphics-locks/`: storage and launch/lifetime locks shared by the app and CLI.
- `Runtimes/`: immutable, version/checksum-specific managed Wine installations with provenance receipts; `.graphics-views/` contains verified private Metal loader views.
- `Components/`: immutable pinned DXVK/DXMT packages and user-imported D3DMetal components, verified receipts, and retained licenses/notices.
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

Development checks on Apple Silicon with macOS 27 and Rosetta, using public Wine 11.0 and an explicitly selected compatible native Wine build for Metal:

- 107 regression tests pass across storage, quarantine/consent, download progress, component integrity/architecture, local Metal imports and native aliases, private loader reuse, reversible cross-backend changes/recovery, rejection of in-place component replacement, displaced user-DLL preservation, graphics concurrency boundaries, and safe Wine CPU repair/backup handling.
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
- With an explicitly selected compatible native Wine loader, DXMT renders and presents 90 frames with GPU clear/readback through 32/64-bit Direct3D 10 and 11. Locally imported D3DMetal passes 64-bit Direct3D 11 and 12 clear/readback and presentation, with the Metal HUD both enabled and disabled.
- The packaged CLI exercises Metal → DXMT → Metal transitions and repeated launches, preserves DLLs during HUD-only changes, blocks launch when the selected import is missing, and restores the complete original prefix graphics footprint without that import. Original custom Wine loader/driver/DLL hashes remain unchanged. Managed Wine rejects both incompatible Metal selections without mutation; its DXVK D3D11 render and Standard restoration still pass.
- The native dashboard and all four backend menu entries render. App-local events open the DXMT and D3DMetal consent dialogs, invoke the real folder-only D3DMetal import panel, and cancel back to Standard without changing bottle metadata. System-backed alert/import-panel snapshots are incomplete without compositor capture permission; their live controls and dismissal were inspected in-process.

Native views were captured in-process, and the fresh-bottle enable/HUD/rollback scenario uses the real application model and Wine processes. Full compositor screenshots and system-wide mouse/keyboard automation were unavailable without Screen Recording and Accessibility permissions; some layer-backed controls are incomplete in the in-process snapshots. Interactive installer completion still requires the normal Windows installer UI. These checks do not establish general Windows-application or game compatibility.

## License and references

MagicWine's original code is **GPL-3.0-or-later**; see [LICENSE](LICENSE). The full Wine distribution is downloaded separately and retains its own licenses and notices. The bundled Wine CPU repair is LGPL-2.1-or-later; `LICENSE-WINE-WOW64CPU.txt` preserves its attribution and license, and its complete corresponding source archive accompanies the DLL in the app/CLI resources and bottle backup. DXVK and the altered macOS fork use the zlib/libpng license. Installed DXVK packages carry both attributions and source/provenance links; `LICENSE-DXVK-DEPENDENCIES.txt` preserves their dependency notices. Bundled DXMT v0.80 is MIT-licensed; `LICENSE-DXMT.txt` and its unchanged upstream release archive are retained in the resources and installation. No proprietary graphics runtime is bundled; local D3DMetal imports remain subject to their own terms.

Whisky and CrossOver supplied in `references/` informed workflow and dependency research. Reference application binaries and assets are not redistributed. The Wine CPU correction comes from the [public LGPL CodeWeavers source mirror](https://github.com/rnowak/wine-crossover-sources/blob/b4f3c510a1808e6e32fb99e9bc11fa46ccc207dc/wine/dlls/wow64cpu/cpu.c), not an extracted CrossOver binary. `references/`, build output, and local verification downloads are ignored by Git. CrossOver and Whisky are independent projects, not affiliations or endorsements.
