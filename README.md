# MagicWine

An open-source, native macOS app for installing and running Windows programs with Wine. Original SwiftUI interface and Swift runtime management; no Electron, background daemon, or bundled proprietary runtime.

## Build and launch

Requires macOS 14 or newer and Swift 6 developer tools. Install Apple's Command Line Tools with `xcode-select --install` if needed.

```sh
./scripts/build-app.sh
open dist/MagicWine.app
```

The script builds the native app for your Mac, creates an ad-hoc-signed development bundle, and also produces `dist/magicwine`, the command-line companion. This is a local development build, not a notarized release. You can open `Package.swift` in Xcode instead.

**Preview toolchains:** the macOS 27 Command Line Tools installed during development omit the SwiftUI state macro plugin. The scripts use the complete installed macOS 26.5 SDK in that specific case; the resulting app still runs on macOS 27. Install complete Xcode tools if neither SDK is available. Set `MAGICWINE_SDK=/path/to/MacOSX.sdk` to select an SDK explicitly. No system developer settings are changed.

## First Windows application

1. Open MagicWine and choose **Install / Update Wine**, then **Trust and Install Wine**, or **Choose Wine Executable** for an existing installation. For a Wine application bundle, the executable is usually inside `Contents/Resources/wine/bin/wine`.
2. Create a bottle. MagicWine initializes its own Windows environment with the selected Wine runtime.
3. Select **Install EXE/MSI** and choose the application's Windows installer. Complete the actual Windows installer normally.
4. Launch its discovered Start Menu shortcut. Use **Refresh Shortcuts** if necessary, or **Add Program** to select an EXE or LNK manually.

**Stop** terminates the selected bottle's Windows processes, not other bottles. **Wine Configuration** opens Wine's settings. **Reveal C: Drive** opens the bottle's Windows files. Errors retain their operation logs; **Reveal Logs** makes them accessible.

Removing a program only removes its MagicWine launcher. Trashing a bottle stops its processes and moves its entire Windows environment to macOS Trash; external executables are not deleted. Failed initialization leaves a bottle available for **Retry Setup**.

## Wine and macOS requirements

MagicWine does not fork or freeze Wine. Managed installation uses the maintained [Gcenx macOS Wine builds](https://github.com/Gcenx/macOS_Wine_builds), with the download URL and SHA-256 checksum from [Homebrew's Wine metadata](https://formulae.brew.sh/api/cask/wine-stable.json). Downloads are staged, checksum-verified, and installed privately without Homebrew or administrator access.

- **Unsigned distribution:** the current public Wine build is unsigned, and Homebrew flags it for Gatekeeper checks. The existing installation confirmation authorizes running unsigned Wine: MagicWine verifies the download checksum and removes only `com.apple.quarantine` inside its managed Wine bundle. This bypasses download-quarantine checks for that bundle, without changing system-wide security settings or custom Wine installations. Other extended attributes are preserved, and symbolic links are not followed. A checksum is integrity verification against metadata, not a publisher signature or malware assessment.
- **Apple Silicon:** Intel Wine requires [Rosetta](https://support.apple.com/102527). Install it yourself through Apple's prompt or `softwareupdate --install-rosetta`, reviewing Apple's license. MagicWine does not install Rosetta or accept the license.
- **Multimedia:** the inspected Wine 11.0_1 distribution's optional multimedia plugin needs the [GStreamer Universal runtime](https://gstreamer.freedesktop.org/download/), version 1.28.2 or newer, in `/Library/Frameworks/GStreamer.framework`. Basic Wine setup and ordinary programs do not require it. MagicWine does not install privileged system frameworks.
- Each bottle **pins its Wine executable**. Installing a newer managed runtime changes the default for new bottles, not existing bottles. Keep runtimes referenced by existing bottles installed. Custom executable paths must also remain available.
- **Already blocked managed Wine:** run **Install / Update Wine** again and accept **Trust and Install Wine**. When the latest runtime is already downloaded, MagicWine checks its provenance receipt and layout, removes its quarantine, and reuses it without downloading the archive again. Existing bottles are not deleted or migrated.

Wine compatibility varies by application. This app does not include CrossOver's application recipes, proprietary D3DMetal/GPTK components, DXVK installation, or a compatibility guarantee for DirectX games, DRM, or anti-cheat. These are not interchangeable with a generic Wine installation.

**A bottle is not a security sandbox.** Windows programs run with your macOS user's permissions, and Wine can expose host files through its drives. Only run software you trust. Logs may contain paths and application output; review them before sharing.

## Command-line companion

```sh
./dist/magicwine --help
./dist/magicwine runtimes
./dist/magicwine create "Windows Apps" "/path/to/wine"
./dist/magicwine list
```

Use the bottle and program UUIDs printed by `list` and `apps` for subsequent commands. `install`, `add`, `refresh`, `launch`, `stop`, and `configure` use the same runtime and storage as the desktop app. `exec` invokes Wine with the bottle's environment and preserves each argument without shell interpolation.

`--root /path/to/data` isolates CLI development data. The CLI managed-download command requires explicit consent: `install-wine --accept-unsigned`. This authorizes unsigned Wine and scoped quarantine removal, including reuse of an existing managed runtime.

## Data and development

Data lives in `~/Library/Application Support/MagicWine/`:

- `Bottles/<UUID>/bottle.json`: atomically saved metadata and launchers.
- `Bottles/<UUID>/prefix/`: Wine prefix and Windows filesystem.
- `Runtimes/`: immutable, version/checksum-specific managed Wine installations with provenance receipts.
- `Logs/`: file-backed process and installation logs; no output-buffer growth while Windows apps run.
- `settings.json`: default and custom Wine selections.

`Sources/MagicWineCore` owns persistence, subprocess lifecycle, runtime discovery, and managed installation. `Sources/MagicWine` owns native UI state and views. `Sources/MagicWineCLI` is the command-line client. Subprocesses wait asynchronously; each bottle has separate UI activity, so another bottle remains usable.

Run deterministic storage regressions with:

```sh
./scripts/test.sh
```

The test script uses the installed Swift Testing plugin and disables XCTest, which is not shipped with this Command Line Tools installation. Real Wine workflow verification is separate from these tests; Wine is not downloaded during the test suite.

## Exercised verification

Development checks on Apple Silicon with macOS 27, Rosetta, and public Wine 11.0:

- Thirteen regression tests pass: four storage tests plus nine quarantine/consent tests covering nested removal, other-attribute preservation, repeat operations, managed-path and symlink boundaries, and refusal without filesystem mutation.
- Two real prefixes keep Windows files separate. Real 7-Zip 26.04 EXE and MSI installations create and validate archives.
- Saved EXEs and installed LNK shortcuts launch real Windows processes. Stop, repeated idle stop, timeout, and task cancellation leave the runtime usable.
- The native app launches and its model runs a Windows GUI program through the running → stop → idle transition without displaying a failure for a requested stop.
- The EXE/MSI installer and Wine configuration entry points open their actual Windows processes, and bottle Stop terminates them.
- Moving a bottle to macOS Trash leaves its externally registered executable unchanged.
- Managed Wine downloads pass checksum/extraction/provenance checks. The native trust confirmation starts a real fresh installation and saves its runtime preference; Wine reports `wine-11.0`. Reinstalling the previously quarantined cached runtime removes its quarantine and also passes Wine version inspection without downloading the archive again.

Native views were captured in-process. Full compositor screenshots and automated mouse/keyboard interaction were unavailable without Screen Recording and Accessibility permissions; some layer-backed controls are incomplete in those snapshots. Interactive installer completion still requires the normal Windows installer UI. These checks do not establish general Windows-application or game compatibility.

## License and references

MagicWine's original code is **GPL-3.0-or-later**; see [LICENSE](LICENSE). Wine and its separately downloaded distribution retain their own licenses and notices. No Wine binary is committed or bundled in the development app.

Whisky and CrossOver supplied in `references/` informed workflow and dependency research only. Their implementations and assets were not copied. `references/`, build output, and local verification downloads are ignored by Git. CrossOver and Whisky are independent projects, not affiliations or endorsements.
