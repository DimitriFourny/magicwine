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

The dark wine-themed library has a searchable bottle sidebar and dedicated **Gamepads**, **Downloads**, **Settings**, and **Documentation** pages. Search filters bottle names, not installed programs. Select a bottle to open its dashboard: pinned runtime and status, installed-program launchers, installer and shortcut actions, graphics controls, logs, and confirmed Trash. Dashboard cards switch from two columns to one in narrower windows.

**Downloads** manages Wine installation and displays installed runtimes. **Settings** chooses the default for new bottles or an existing Wine executable; existing bottles retain their pinned runtime. The sidebar **+** button and **Command-N** open bottle creation. Native file pickers, installer URL handling, Wine trust confirmation, and bottle-specific busy/stop guards remain in place.

## First Windows application

1. Open **Downloads**, click **Install Wine…**, and confirm **Trust and Install Wine**. The single managed Wine includes MagicWine's bundled DXMT-compatible driver; DXMT itself is also bundled.
2. Create a bottle. MagicWine uses your preferred Wine automatically and initializes its Windows environment with **Standard** graphics. Custom Wine selection is optional under **Advanced** in Settings and bottle creation.
3. Select **Install EXE/MSI** and choose the application's Windows installer. Complete the actual Windows installer normally.
4. Launch its discovered Start Menu shortcut. Use **Refresh Shortcuts** if necessary, or **Add Program** to select an EXE or LNK manually.

Only the current managed Wine is selected automatically. Discovery excludes obsolete managed installations. If a saved managed preference points to an older build, MagicWine selects the current build when installed; otherwise bottle creation asks you to **Install Wine** first. Other discovered Wine installations require an explicit choice under Advanced. An unavailable custom preference is not silently replaced with a different Wine.

Managed Wine downloads show a progress bar, percentage, received/total size, and recent download speed. If the server does not supply a total size, the bar stays indeterminate while received bytes and speed still update. Checksum verification, extraction, preparation, and runtime inspection have separate status messages. An already-installed runtime is reused without displaying a fictitious download.

**Stop** terminates the selected bottle's Windows processes, not other bottles. **Wine Configuration** opens Wine's settings. **Reveal C: Drive** opens the bottle's Windows files. Errors retain their operation logs; **Reveal Logs** makes them accessible.

Removing a program only removes its MagicWine launcher. Trashing a bottle stops its processes and moves its entire Windows environment to macOS Trash; external executables are not deleted. Failed initialization leaves a bottle available for **Retry Setup**.

## Wine and macOS requirements

Managed installation downloads one pinned Wine `11.0_1` archive from the public [Gcenx macOS Wine builds](https://github.com/Gcenx/macOS_Wine_builds) and installs MagicWine's public-source-built Wine 11 macOS driver and matching native/Windows runtime modules. It supports Standard, DXVK, and, on compatible Apple Silicon Macs, DXMT and locally imported D3DMetal. This modified runtime is not an official Wine, Gcenx, CodeWeavers, Apple, or DXMT distribution.

The Wine Metal support modules and DXMT component ship with MagicWine. **The initial Wine archive still downloads; enabling DXMT needs no additional download.** D3DMetal's proprietary libraries are discovered or imported locally, not bundled or downloaded. Original Wine modules, complete corresponding source, LGPL notice, and build provenance are retained in `runtime-compatibility/winemac-wine11.0-metal.2/`.

Downloads are staged and checksum-verified without Homebrew or administrator access. The matched native and 32/64-bit Windows modules are installed in a private staging tree before the complete runtime is published. The per-bottle CPU repair described below remains separate.

- **Unsigned distribution:** the managed Wine runtime is unsigned. Installation confirmation authorizes running it: MagicWine verifies the pinned download checksum and removes only `com.apple.quarantine` inside its managed Wine bundle. This bypasses download-quarantine checks for that bundle, without changing system-wide security settings or custom Wine installations. Other extended attributes are preserved, and symbolic links are not followed. A checksum verifies integrity against the pinned hash, not a publisher signature or malware assessment.
- **Apple Silicon:** Intel Wine requires [Rosetta](https://support.apple.com/102527). Install it yourself through Apple's prompt or `softwareupdate --install-rosetta`, reviewing Apple's license. MagicWine does not install Rosetta or accept the license.
- **Multimedia:** the inspected Wine 11.0_1 distribution's optional multimedia plugin needs the [GStreamer Universal runtime](https://gstreamer.freedesktop.org/download/), version 1.28.2 or newer, in `/Library/Frameworks/GStreamer.framework`. Basic Wine setup and ordinary programs do not require it. MagicWine does not install privileged system frameworks.
- Each bottle **pins its Wine executable**. Keep that runtime installed; custom executable paths must also remain available.
- **Already blocked managed Wine:** click **Install Wine…** again and accept its trust confirmation. MagicWine verifies the pinned native driver, original backup, source, notices, provenance receipt, and layout before removing quarantine and reusing it without another download. Invalid cached installations are rejected without repair or replacement.

Wine compatibility varies by application. MagicWine offers optional DXVK, DXMT, and locally imported D3DMetal backends below. It does not bundle CrossOver's application recipes or proprietary D3DMetal/GPTK components, or guarantee compatibility with DirectX games, DRM, or anti-cheat.

**A bottle is not a security sandbox.** Windows programs run with your macOS user's permissions, and Wine can expose host files through its drives. Only run software you trust. Logs may contain paths and application output; review them before sharing.

## Rosetta and legacy browser launchers

On Apple Silicon, the verified stock Wine 11.0 CPU transition code can crash while starting 32-bit .NET launchers under Rosetta. MagicWine bundles `wow64cpu-wine11.0-magicwine.1`, built from public Wine source with CodeWeavers' Rosetta far-call/far-return correction (CW HACK 20760). This fixes Tropics Demo v1.3's failure before its settings window appears; no CrossOver binary is used.

Before launching an initialized bottle, MagicWine checks the runtime version and original CPU DLL SHA-256, then atomically replaces only that bottle's known-stock `system32/wow64cpu.dll`. Its original DLL, corresponding source, and LGPL notice are preserved in `runtime-compatibility/wow64cpu-wine11.0-magicwine.1/`. Keep that backup intact. Custom prefix DLLs, links, corrupt resources, and missing or modified backups are rejected rather than overwritten; unknown runtime builds are left untouched. The process-local `wow64cpu=n` override is independent of DXVK and its HUD. Shared Wine files and bottle metadata are unchanged.

Launches also prefer application-provided `SHDocVw.dll` with `shdocvw=n,b`, retaining Wine's built-in fallback. This prevents Wine's namesake browser DLL from replacing the managed interop assembly shipped with older .NET launchers.

Rebuild with `brew install mingw-w64 python` and `bash scripts/build-wow64cpu.sh`. The recipe verifies pinned Wine and public CodeWeavers source, applies `patches/wine-wow64cpu-rosetta.patch`, and retains tool/source/command provenance under `.local/wow64cpu-magicwine-build.*/`. The bundled `wow64cpu-wine11.0-magicwine.1-source.tar.gz` contains the complete inputs and recipe for rebuilding offline with those tools. Update the independent resource pins in `RosettaCPUCompatibility.swift` when rebuilding with a different toolchain.

The original Tropics settings window and browser controls were exercised through the packaged saved shortcut. Its **Run** button has a separate `forms.settings` scripting failure reproduced in both MagicWine and the isolated CrossOver reference; it is intentionally unchanged, as are the game's files. Use the working DirectX demo shortcuts to start the game.

## Unity / embedded Mono startup

The managed Metal runtime keeps macOS pthread GS active for native Metal code. Older Windows Mono JITs read dynamic TLS directly from Windows GS offsets, which instead address native pthread storage in this runtime. ULTRAKILL Demo (Unity 2019.4.0f1) consequently faults during Mono initialization; recursive exception handling ends in Wine's `stack overflow` error before graphics-device creation.

For launches using managed Metal Wine in this library, including older pinned Metal builds, MagicWine adds `use-fallback-tls` to the process-local `MONO_DEBUG` options. This [Mono-supported mode](https://github.com/Unity-Technologies/mono/blob/d9ad36f4a70e55923604172a47f2223f4f6df5b6/mono/mini/mini-amd64.c#L3429-L3431) uses TLS helpers instead of inline GS access. Existing options are preserved, and the option is not duplicated. It applies independently of the graphics selection; custom runtimes and earlier non-Metal managed builds are unchanged. No game DLLs, bottle metadata, Wine binaries, registry settings, or global environment variables are modified by this launch correction. Rebuild and restart MagicWine to apply it to existing bottles; Wine reinstallation is unnecessary for the Mono correction.

Verification covers ULTRAKILL startup with DXVK in an isolated prefix and the rebuilt CLI with D3DMetal in the original bottle: engine/assembly/input initialization, scene loading, and a responsive 960×540 game window. Screen capture was unavailable, so visual correctness and gameplay are not certified. Discord integration still logs an `InternalError`, without preventing this startup. This is a Mono compatibility workaround, not a complete repair of direct Windows GS access for other applications.

## Unity 6 mouse input

House Flipper 2 (Unity 6000.3.7f1) uses Windows mouse-in-pointer input. Stock Wine 11 reports `EnableMouseInPointer ... Call not implemented`; mouse enumeration and raw-input registration can succeed while the game's pointer-based mouse handling remains inactive. This is separate from cursor confinement and affects DXVK, DXMT, and D3DMetal alike. Older Unity input, such as ULTRAKILL Demo's, need not use this API.

Managed runtime `winemac-wine11.0-metal.2` includes a source-level mouse-pointer backport in `patches/wine-mouse-pointer.patch`, based on [Wine's mouse-in-pointer implementation](https://github.com/wine-mirror/wine/commit/71b686ce9fdce65416080c834a9103a743dc095c) and subsequent pointer-info/WoW64 work attributed in the patch. It delivers mouse pointer messages and queryable per-thread frames, including all five buttons, held-button motion, partial releases, and signed wheel input. Classic and raw mouse delivery remain available. Process enablement is immutable after its first choice, and merely peeking at a message does not duplicate pointer delivery.

The fix is runtime-wide: there are no executable-name checks or HF2-specific game patches. Other games using this mouse-in-pointer path receive the same support when launched with the updated runtime.

The installer publishes ten matched native/Windows modules, preserving their stock originals and complete corresponding source. It does not modify existing Wine installations or game DLLs. Install Wine again to obtain this new build; existing bottles remain pinned to their previous runtime unless explicitly migrated. New bottles use the new managed runtime. Do not copy individual `user32`/`win32u` modules from another Wine or CrossOver build into a bottle.

This backport handles mouse input, not complete Windows pen/touch support, pointer history, or implicit pointer capture. Its pointer synthesis follows accepted classic mouse messages; pointer-only message filters and applications suppressing classic input with `RIDEV_NOLEGACY` are not covered.

Run the real 32/64-bit mouse-input regression against a selected Wine runtime with `bash scripts/test-mouse-pointer.sh "/absolute/path/to/wine/bin/wine"`. It uses MinGW compilers and a disposable prefix, exercises input through `SendInput`, and verifies pointer frames, dragging, wheel signs, legacy/raw delivery, process/thread boundaries, and non-removing peeks.

House Flipper 2 was launched through the normal saved-program path in an isolated bottle, and the user confirmed working mouse input. Automated verification additionally covers 32/64-bit font rasterization and Vulkan GPU enumeration, preserving those capabilities of the rebuilt window/input module. Screen capture was unavailable; no independent visual gameplay certification is claimed.

## Gamepads

Open **Gamepads** in the sidebar. Pair a controller in macOS Bluetooth settings or connect it by USB. MagicWine discovers controllers supported by Apple's GameController framework with an extended gamepad layout, including supported Xbox and PlayStation controllers. Up to four controllers receive stable XInput player slots; additional devices can be inspected without pretending they have a game slot.

- **Controller Overview** shows physical input; **Live Input Test** previews the selected draft profile's mapped output, with stick plots, triggers, and button indicators.
- Remap individual buttons, stick clicks, triggers, and D-pad directions, or choose **Unmapped**. Stick movement stays analog.
- Adjust radial stick dead zones, response curves, trigger sensitivity, and vibration strength. **Calibrate** measures the current resting position: release both sticks before **Capture Center**.
- **Identify** sends a short physical vibration when the controller exposes haptics. Game rumble uses separate handle motors where available, or the controller's default haptic output otherwise.
- Select, duplicate, rename, delete, import, or export JSON profiles. **Save Changes** persists the selected profile and applies it to all bridged controllers, including running games. Draft edits only affect the preview until saved. Corrupt profiles surface an error instead of silently resetting.

**Keep MagicWine running while playing**, or keep the launching CLI process alive. Launch the game through the updated app/CLI; already-running games need a restart to load the bridge. The saved global profile is shared by bottles in the same MagicWine library. The bridge works independently of Standard, DXVK, DXMT, or D3DMetal graphics selection.

Before launching an initialized bottle, MagicWine installs its original, SHA-pinned 32/64-bit XInput bridge for `xinput1_1`, `xinput1_2`, `xinput1_3`, `xinput1_4`, and `xinput9_1_0`. It retains Wine's original system DLLs, links, and absent paths under `runtime-compatibility/magicwine-xinput-v1/`, alongside source and the GPL license. Custom system XInput replacements and damaged backups are rejected, not overwritten. Shared Wine and game-local DLLs are unchanged; application-local controller middleware retains native-first precedence. The bridge uses the prefix's normal `Z:` host drive to reach a private, process-specific controller mapping. Do not remove that drive while using this bridge.

Controller input and rumble cross a bounded shared-memory mapping with heartbeat and sequence checks. Disconnecting or losing the host clears input; abandoned vibration expires within two seconds. Unknown battery information stays unknown. XInput has no gyroscope channel: gyro, controller audio/headsets, power-off, and vendor-specific controls are not emulated. DirectInput-only games still use Wine's own input support; these profiles do not remap DirectInput.

Battery charge uses GameController first. For Bluetooth gamepads whose battery is absent there, MagicWine reads macOS's Bluetooth report asynchronously every 30 seconds and matches only unique, exact device names. Ambiguous or unavailable readings remain unknown; a Bluetooth percentage alone does not imply charging.

Rebuild the bundled DLLs with `bash scripts/build-gamepad-bridge.sh` (MinGW-w64 and Python required), then update the independent hashes in `GamepadBridge.swift`. Run `bash scripts/test-gamepads.sh "/absolute/path/to/wine/bin/wine"` for real 32/64-bit XInput API checks in a disposable prefix, including sustained rumble and competing writers. Verification also exercises processed Swift input through Wine and return vibration, background CLI heartbeat, and native UI rendering. Physical Bluetooth battery reporting was verified with an 8BitDo Ultimate 2 Wireless; USB/Bluetooth gameplay, physical haptics, and The Witcher 3 remain hardware/game checks, not certified compatibility.

## Graphics and game testing

Every new bottle defaults to **Standard**. Enable another backend explicitly in its Graphics controls.

| Backend | Translation provided | Component and requirements |
| --- | --- | --- |
| Standard | Wine's built-in graphics | Depends on the bottle's pinned Wine runtime |
| DXVK — Experimental | 32/64-bit Direct3D 9/10/11 → Vulkan/MoltenVK | Bundled macOS fork; supported by managed Wine |
| DXMT — Experimental | 32/64-bit Direct3D 10/11 → Metal | Bundled DXMT v0.80; Apple Silicon, macOS 15+, managed Wine or compatible native custom Wine |
| D3DMetal — Experimental | 64-bit Direct3D 11/12 → Metal | Locally imported Apple libraries; Apple Silicon, macOS 14+ or the library's higher minimum, managed Wine or compatible native custom Wine |

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

**DXMT works with the default managed Wine.** Install Wine once, create a bottle, then enable DXMT in Graphics on a supported Apple Silicon Mac running macOS 15 or newer. No separate Wine variant or DXMT download is needed. Compatible custom native Wine remains supported.

**D3DMetal also works with the default managed Wine.** Confirm **Enable D3DMetal** in Graphics; an installed CrossOver's libraries are discovered automatically as described below. A separate custom Wine loader is not required. Compatible custom GPTK/Whisky/CrossOver native Wine remains supported; select a native `wine`/`wineloader`, not a shell/Perl wrapper that rewrites `WINEPREFIX` or DLL selection. After upgrading from the prerelease DXMT-only runtime, use **Install Wine** and create a bottle with the current preferred Wine.

Wine's Metal support is rebuilt by `bash scripts/build-metal-wine.sh` from pinned public Wine 11 source with `patches/wine-metal-driver.patch`. The recipe requires the recorded Apple clang/SDK, Bison, and MinGW toolchains; users installing Wine through MagicWine do not need build tools. Six compressed native/Windows images and complete source/provenance ship with the app and CLI. Opaque RFC1951 payloads prevent packaging from rewriting pinned images. The driver implements the published 24-slot D3DMetal interface, including DXMT's shared prefix, and owns real Wine client surfaces through presentation, resize, and window destruction. Matching `ntdll` modules provide the legacy Unix-call export, native D3DMetal calling conventions, and synchronized Windows/native thread-local storage. Following CodeWeavers' public implementation, each Wine process redirects its own libc `localtime` entrypoint to separate thread-local storage; no system file is modified, and executable-page write protection is restored immediately.

DXMT installs the unchanged [v0.80 builtin release](https://github.com/3Shain/dxmt/releases/tag/v0.80) offline. Its archive SHA-256 is `8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`; the managed identifier is `dxmt-v0.80`. It checks the Apple GPU family, native Wine exports, archive layout, PE/Mach-O architecture, and pinned payload hashes. It selects `d3d10core`, `d3d11`, `dxgi`, and `winemetal` for both Windows architectures, plus the native Metal bridge. It does not replace Direct3D 9 or 12. See the [upstream installation guide](https://github.com/3Shain/dxmt/wiki/DXMT-Installation-Guide-for-Geeks) for compatible Wine requirements.

D3DMetal is **local import only**. After you confirm **Enable D3DMetal**, MagicWine looks for libraries beside the bottle's selected Wine first, then in `~/Applications/CrossOver.app` and `/Applications/CrossOver.app`. It uses the local `lib64/apple_gptk`, `lib/apple_gptk`, or toolkit `lib` payload without a file picker when found; it does not change the bottle's pinned Wine. You must have the right to use those libraries under the terms accompanying your distribution, including the applicable [Apple Game Porting Toolkit terms](https://developer.apple.com/games/game-porting-toolkit/).

If no libraries are found, MagicWine opens **Import D3DMetal Libraries**. Select an extracted evaluation-environment folder containing `redist/lib`, that `lib` folder, or a compatible `apple_gptk` root containing `external/` and `wine/`. A framework alone is insufficient: the matching 64-bit Windows DLLs, Unix shared-bridge aliases, `libd3dshared.dylib`, framework resources, and dependency notices are required. Automatically discovered libraries undergo the same complete validation as manual imports. Conventional framework/shared-library links and byte-identical materialized aliases are supported; escaping links and mismatched bridge versions are rejected.

MagicWine does not download Apple libraries, accept their license, modify their bytes, re-sign them, or remove their quarantine. It copies and verifies the selected payload into a content-addressed `d3dmetal-<SHA-256>` component and preserves accompanying notices. A configured bottle can launch and change its HUD without the original source folder. Switching another backend to D3DMetal discovers the source again, asking for a folder only when needed; an identical import reuses its verified component. To replace a component version, restore Standard first, then enable the new component.

Wine searches its native runtime directory before `WINEDLLPATH`. Metal launches therefore use a private, verified runtime view under `Runtimes/.graphics-views/`: unchanged copies of loaders and native Wine modules, links to other runtime files, and selected graphics overlays. Native Wine modules and DXMT's `winemetal.so` must be physical copies so dyld's loader-relative dependencies stay inside the view instead of loading a second original `ntdll.so`. Apple's Unix aliases still resolve to one canonical shared image, preserving native global state and framework lookup without `DYLD_*` overrides. Switching graphics leaves the selected runtime and imported-library bytes/signatures unchanged. Keep the selected managed or custom runtime available.

**Show Graphics HUD** enables Apple's Metal HUD for DXMT/D3DMetal. HUD-only changes stop the bottle but do not reinstall its DLLs. DXMT logs go to `Logs/<bottle-UUID>-dxmt/`, with its shader cache in the bottle's `graphics/dxmt-cache/`; D3DMetal diagnostics use the Wine operation log. All launch overrides are process-local. Neither Metal backend translates OpenGL, and no general game, anti-cheat, fullscreen, or performance guarantee is implied.

## Command-line companion

```sh
./dist/magicwine --help
./dist/magicwine runtimes
./dist/magicwine create "Windows Apps" "/path/to/wine"
./dist/magicwine list
```

Use the bottle and program UUIDs printed by `list` and `apps` for subsequent commands. `install`, `add`, `refresh`, `launch`, `stop`, and `configure` use the same runtime and storage as the desktop app. `exec` invokes Wine with the bottle's environment and preserves each argument without shell interpolation.

`--root /path/to/data` isolates CLI development data. Managed installation requires explicit consent: `install-wine --accept-unsigned` installs the single pinned Wine runtime with its bundled DXMT driver bridge. This authorizes unsigned Wine and scoped quarantine removal, including cached reuse. Use the printed Wine path with `create`; there is no distribution-selection flag.

Graphics commands use the same reversible setup:

```sh
./dist/magicwine graphics <bottle-UUID>
./dist/magicwine graphics <bottle-UUID> dxvk --accept-experimental --hud
./dist/magicwine graphics <bottle-UUID> dxvk --accept-experimental --no-hud
./dist/magicwine graphics <bottle-UUID> dxmt --accept-experimental --hud
./dist/magicwine graphics <bottle-UUID> d3dmetal --accept-experimental
./dist/magicwine graphics <bottle-UUID> d3dmetal --accept-experimental --import "/path/to/redist/lib"
./dist/magicwine graphics <bottle-UUID> d3dmetal --accept-experimental --no-hud
./dist/magicwine graphics <bottle-UUID> standard
```

Core clients install with `WineRuntime.installRuntime(acceptUnsigned:progress:)`. The single managed runtime includes the DXMT driver bridge. Consent is required before filesystem changes; enabling DXMT separately validates its host and graphics requirements.

Core clients use `WineRuntime.configureGraphics(_:in:showHUD:acceptExperimental:componentSource:progress:)`; every nonstandard backend requires `acceptExperimental: true`. D3DMetal automatically discovers local Wine/CrossOver libraries when `componentSource` is omitted. Pass `componentSource` (CLI: `--import`) to explicitly select a source instead; it is not accepted for other backends. `WineRuntime.discoverD3DMetalSource(executable:)` exposes the same location lookup for import UI; installation still performs full validation. `BottleStore.save` rejects direct or stale graphics changes. Launch/setup gates also protect against another MagicWine CLI process replacing DLLs during a launch.

## Data and development

Data lives in `~/Library/Application Support/MagicWine/`:

- `Bottles/<UUID>/bottle.json`: atomically saved metadata and launchers.
- `Bottles/<UUID>/prefix/`: Wine prefix and Windows filesystem.
- `Bottles/<UUID>/graphics/`: original-DLL backups, interrupted-change recovery, retained custom replacements, and per-bottle DXVK/DXMT shader caches.
- `Bottles/<UUID>/runtime-compatibility/`: verified original Wine CPU and XInput DLLs, corresponding source, and license notices.
- `Bottles/.graphics-locks/`: storage and launch/lifetime locks shared by the app and CLI.
- `Runtimes/`: immutable, version/checksum-specific managed Wine installations with provenance receipts; `.graphics-views/` contains verified private Metal loader views.
- `Components/`: immutable pinned DXVK/DXMT packages and user-imported D3DMetal components, verified receipts, and retained licenses/notices.
- `Logs/`: file-backed process and installation logs; no output-buffer growth while Windows apps run.
- `settings.json`: default and custom Wine selections.
- `Gamepads/profiles.json`: validated gamepad profiles and the active global profile.
- `Gamepads/Sessions/`: private, process-specific live input/rumble mappings; stale sessions report disconnected.

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

Development checks on Apple Silicon with macOS 27 and Rosetta, using the default managed Wine and an explicitly selected compatible custom native Wine build:

- 118 regression tests pass in the release configuration across storage, quarantine/consent, managed-cache integrity, preferred-runtime selection, native-driver integrity/ABI boundaries, download progress, local Metal discovery/imports and native aliases, private loader reuse/tamper rejection, reversible graphics changes/recovery, displaced user-DLL preservation, graphics concurrency, and safe Wine CPU repair/backup handling.
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
- The packaged CLI exercises Metal → DXMT → Metal transitions and repeated launches, preserves DLLs during HUD-only changes, blocks launch when the selected import is missing, and restores the complete original prefix graphics footprint without that import. Original custom Wine loader/driver/DLL hashes remain unchanged. Unmodified upstream Wine 11 rejects both incompatible Metal selections without mutation; its DXVK D3D11 render and Standard restoration still pass.
- The native dashboard and all four backend menu entries render. App-local events open the DXMT and D3DMetal consent dialogs, invoke the real folder-only D3DMetal import panel, and cancel back to Standard without changing bottle metadata. System-backed alert/import-panel snapshots are incomplete without compositor capture permission; their live controls and dismissal were inspected in-process.
- With a fresh managed-Wine bottle, the final packaged app switches DXMT → D3DMetal → DXMT through native picker and confirmation actions. It discovers `/Applications/CrossOver.app` without a folder panel and preserves the bottle's Wine path. Dashboard captures show both saved selections. CLI D3DMetal selection without `--import` uses the same discovery and validation. An unmodified upstream Wine 11 DXVK bottle still shows the DXMT compatibility error and retains DXVK.
- The packaged app offers one Wine install, cancels trust without installing, then completes a real consent/download and saves the default. Bottle creation uses it automatically, with runtime overrides hidden under Advanced. The initialized bottle starts with Standard; native DXMT confirmation persists without reverting.
- Fresh packaged CLI installation, bottle initialization, and cached reuse succeed; the removed distribution-selection flag is rejected. The current managed runtime presents 90 D3D11 triangle frames with verified GPU readback, resize, and swapchain recreation in both architectures through DXMT and DXVK. Restored Standard presents 60 D3D9 triangle frames with verified GPU readback in each architecture.
- With the revised native runtime views, custom Wine still passes both DXMT shader probes and automatic D3DMetal import plus 64-bit shader rendering, then restores Standard.
- With the reported obsolete managed path saved as preferred, the native new-bottle sheet requires current Wine instead of accepting the old installation. Its trust/install flow then creates a Standard bottle with current Wine and successfully enables DXMT. Restarting with both installations present and the stale preference restored corrects the saved preference without reinstalling, creates another current-Wine bottle, and enables DXMT through native menu/confirmation actions. The old driver bytes remain unchanged; a Windows command runs through the corrected bottle's DXMT runtime view.
- The packaged managed runtime renders 90 hardware D3D11 and 30 hardware D3D12 triangle frames through automatically imported Apple libraries, with verified foreground/background GPU readback, resizing, and swapchain recreation on the same window. Native probes exercise the complete 24-slot driver interface, including real display, registry, monitor, and window operations, its Windows calling conventions, direct user-stack calls, and WoW64 callback marshalling.
- Both 32-bit and 64-bit PE TLS probes load 80 TLS-bearing modules into eight pre-existing threads, verify independent values after TLS-vector growth, and complete thread teardown.

Native views were captured in-process, and the fresh-bottle enable/HUD/rollback scenario uses the real application model and Wine processes. Full compositor screenshots and system-wide mouse/keyboard automation were unavailable without Screen Recording and Accessibility permissions; some layer-backed controls are incomplete in the in-process snapshots. Interactive installer completion still requires the normal Windows installer UI. These checks do not establish general Windows-application or game compatibility.

## License and references

MagicWine's original code is **GPL-3.0-or-later**; see [LICENSE](LICENSE). The full Wine distribution is downloaded separately and retains its own licenses and notices. The bundled Wine CPU repair is LGPL-2.1-or-later; `LICENSE-WINE-WOW64CPU.txt` preserves its attribution and license, and its complete corresponding source archive accompanies the DLL in the app/CLI resources and bottle backup. The managed Wine Metal driver and runtime modules are also LGPL-2.1-or-later; `LICENSE-WINE-METAL.txt`, the complete source archive, patch, build recipe, and provenance accompany the compressed images and installed original-module backups. The D3DMetal ABI port follows the public [CodeWeavers source](https://github.com/rnowak/wine-crossover-sources/tree/b4f3c510a1808e6e32fb99e9bc11fa46ccc207dc/wine/dlls/ntdll) and [Whisky driver interface](https://github.com/Whisky-App/wine/blob/a92f7f06c4cff7291578e58eb95284b00e322799/dlls/winemac.drv/macdrv_main.c), with TLS synchronization informed by [WineForge](https://github.com/Alien4042x/WineForge/tree/a342f4aeb23d719339f444b9e94e06ecf0ff1a14). DXVK and the altered macOS fork use the zlib/libpng license. Installed DXVK packages carry both attributions and source/provenance links; `LICENSE-DXVK-DEPENDENCIES.txt` preserves their dependency notices. Bundled DXMT v0.80 is MIT-licensed; `LICENSE-DXMT.txt` and its unchanged upstream release archive are retained in the resources and installation. No proprietary graphics runtime is bundled; local D3DMetal imports remain subject to their own terms.

Whisky and CrossOver supplied in `references/` informed workflow and dependency research. Reference application binaries and assets are not redistributed. The Wine CPU correction comes from the [public LGPL CodeWeavers source mirror](https://github.com/rnowak/wine-crossover-sources/blob/b4f3c510a1808e6e32fb99e9bc11fa46ccc207dc/wine/dlls/wow64cpu/cpu.c), not an extracted CrossOver binary. `references/`, build output, and local verification downloads are ignored by Git. CrossOver and Whisky are independent projects, not affiliations or endorsements.
