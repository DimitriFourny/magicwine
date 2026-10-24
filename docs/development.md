# Development and verification

[Documentation index](README.md) · [Architecture](architecture.md) · [Debugging](debugging.md)

The ordinary Swift app build packages checked-in compatibility resources. It does not rebuild Wine, DXVK, DXMT, or the XInput bridge. Component recipes are a separate, more constrained workflow.

## Build prerequisites

The Swift package declares Swift tools 6.0 and macOS 14 as its minimum deployment target. Use a complete Xcode or Command Line Tools installation selected by `xcrun`. The package has no external Swift package dependencies. Individual graphics backends have stricter host requirements; see [Graphics](graphics.md).

From the repository root:

```sh
./scripts/build-app.sh
open dist/MagicWine.app
./dist/magicwine --help
```

[build-app.sh](../scripts/build-app.sh) builds release executables, packages the native app and CLI, validates `Info.plist`, and ad-hoc signs the app. It is a local development distribution, not a Developer ID-signed or notarized release. Re-running replaces generated resource bundles under `dist/`; put no hand-maintained files there.

The script does not install Wine, accept runtime trust prompts, or rebuild the bundled graphics libraries. Wine can be installed later through the app or CLI with explicit consent. Rosetta installation and license review remain the user's responsibility.

### SDK selection

[toolchain.sh](../scripts/toolchain.sh) derives the toolchain from `xcrun --find swiftc` and chooses the active macOS SDK. An explicit override is a filesystem path:

```sh
MAGICWINE_SDK="/absolute/path/to/MacOSX.sdk" ./scripts/build-app.sh
```

There is a narrow fallback for the macOS 27 Command Line Tools layout when its SwiftUI macro plugin is absent: the script selects an already installed macOS 26.5 SDK. It does not download an SDK or change `xcode-select`. A missing/incomplete toolchain is not fixed by suppressing linker or macro errors. The standalone patched-Wine build has its own stricter SDK/tool requirements and does not use this override.

For a separately named development app:

```sh
MAGICWINE_APP_NAME="MagicWine Research" \
MAGICWINE_BUNDLE_ID="org.magicwine.research" \
./scripts/build-app.sh
```

The executable inside that renamed bundle is still `Contents/MacOS/MagicWine`. A distinct bundle identity does not select a distinct data root; use the isolated-root launch below.

## Distribution layout

```text
dist/
├── magicwine
├── LICENSE
├── THIRD_PARTY_NOTICES.md
├── MagicWine_MagicWineCore.bundle/
│   └── Contents/Resources/             # pinned component payloads and notices
└── MagicWine.app/
    └── Contents/
        ├── Info.plist
        ├── MacOS/MagicWine
        └── Resources/
            ├── AppIcon.icns
            ├── LICENSE
            ├── THIRD_PARTY_NOTICES.md
            ├── MagicWine_MagicWineCore.bundle/
            └── MagicWine_MagicWine.bundle/
```

Keep the core resource bundle beside the CLI when moving it. `Bundle.module` lookup and runtime installation need these resources; a standalone copied executable is incomplete. GUI artwork is a separate processed bundle. Core payloads use `.copy` in [Package.swift](../Package.swift), including compressed native Wine images to preserve their pinned bytes.

Source archives, original upstream packages, and notices are runtime/distribution inputs, not build debris. Do not remove them to reduce repository size. [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) explains MIT versus component-specific license boundaries.

## Isolated native and CLI work

Both commands below select the same separate library. Run the app executable directly so the environment override reaches this process:

```sh
ROOT="$PWD/.local/research-library"
./dist/magicwine --root "$ROOT" list
MAGICWINE_DATA_ROOT="$ROOT" ./dist/MagicWine.app/Contents/MacOS/MagicWine
```

CLI `--root` must come before its command. The CLI does not use `MAGICWINE_DATA_ROOT`; the GUI does. An empty-library `list` creates its directory hierarchy and produces no rows. Native startup also discovers installed host Wine and starts controller monitoring, so isolation of saved data does not mean zero host interaction. Neither root selection nor Wine prefixes are security sandboxes.

Never point integration experiments at a valuable game prefix. See [Debugging](debugging.md) for creating a research bottle and preserving useful evidence.

## Swift tests

```sh
./scripts/test.sh
./scripts/test.sh --filter GamepadBridgeTests
./scripts/test.sh --filter BottleSynchronizationTests
```

[test.sh](../scripts/test.sh) forwards arguments to `swift test`, selects the same SDK helper, disables XCTest, and supplies the Swift Testing plugin path when available. The tests use Swift Testing. Do not substitute `--help` on a build script as a safe inspection command: most build scripts do not parse it and will build anyway.

The [test directory](../Tests/MagicWineCoreTests/) covers persistence, safe paths, shortcut/icon parsing, display/synchronization state, graphics transactions/leases, component validation, profile transforms, and compatibility backup rules. `SecureFSTests` covers the shared filesystem, hashing, Mach-O and PE helpers described in [architecture](architecture.md#packaged-resources-and-trust); component suites remain the regression net for each caller's policy. Tests use isolated fixtures; they do not establish that a real Windows game renders, receives physical input, or survives a launcher workflow.

## Real Wine verification

Use an absolute trusted Wine executable with its matching adjacent `wineserver`. These runners create temporary prefixes or application roots, execute real Wine, and clean up their own state. GUI/input/rendering probes require a usable graphical macOS session; they are not all suitable for headless CI. No runner below downloads Wine for you.

| Runner | Prerequisites beyond Wine | What it exercises |
| --- | --- | --- |
| `test-gamepads.sh` | Both MinGW GCC cross-compilers; WoW64 Wine | Both Windows XInput ABIs with test-controlled shared state; no physical controller required |
| `test-mouse-pointer.sh` | Both MinGW GCC cross-compilers; patched WoW64 Wine; graphical input | Enabled/disabled mouse-pointer behavior and classic/raw delivery |
| `test-wine-proxy.sh` | Both MinGW GCC cross-compilers; WinHTTP runtime | Argument handling and real loopback PAC evaluation; optional host-disabled WPAD check |
| `test-wine-proxy.sh --native` | Patched source, configured Wine build, Apple clang; Rosetta on ARM | Actual native helper with controlled proxy dictionaries, including ABI/policy boundaries |
| `test-remote-presentation.sh` | Built CLI and adjacent bundle; matching Metal-capable Wine; MinGW C++; compatible GPU/session; discoverable local D3DMetal if selected | Foreign-window presentation, resize/reparent/lifetime, GPU readback, HUD off/on |
| `test-msync.sh` | Python 3; both MinGW GCC cross-compilers; paired MSync-capable WoW64 Wine/server | Real waits, shared objects, mode agreement, and explicit off/on behavior |

Exact invocations from the checkout:

```sh
WINE="/absolute/path/to/wine/bin/wine"
CLI="$PWD/dist/magicwine"

bash scripts/test-gamepads.sh "$WINE"
bash scripts/test-mouse-pointer.sh "$WINE"
bash scripts/test-wine-proxy.sh "$WINE"
bash scripts/test-wine-proxy.sh "$WINE" --expect-disabled
bash scripts/test-wine-proxy.sh --native "/absolute/path/to/patched/wine/source" "/absolute/path/to/configured/wine/build"
bash scripts/test-remote-presentation.sh "$CLI" "$WINE" dxmt
bash scripts/test-remote-presentation.sh "$CLI" "$WINE" d3dmetal --visual
bash scripts/test-msync.sh "$WINE"
bash scripts/test-msync.sh "$WINE" --benchmark
```

These are independent scenarios, not a sequence to run indiscriminately. In particular:

- `--expect-disabled` requires a host whose proxy autodiscovery is already disabled. The runner does not change network settings.
- `--native` compiles the actual patched WinHTTP Unix helper, substituting host-policy acquisition only inside the test binary. It is not a live-network-policy test.
- Remote presentation covers both Windows architectures for DXMT and only 64-bit D3DMetal. It has no `--import` option; Apple libraries must be discoverable locally. `--visual` holds rendered output briefly for inspection instead of claiming compositor correctness from GPU readback.
- MSync uses separate servers/prefixes for off/on and 32/64-bit combinations, requires the real startup marker, rejects an opposite-mode client, then checks that the original mode still works. `--benchmark` adds a bounded 20,000-round-trip handoff measurement, not an FPS test or a required speedup.
- Temporary failure logs are generally removed during cleanup. MSync and remote-presentation runners dump diagnostic output on failure; capture the console output if needed. For longer investigations, build a dedicated research library rather than modifying a runner to use a production bottle.
- Controller API tests do not certify physical rumble or Bluetooth behavior. Mouse tests synthesize real input and can interact with the graphical session.

Script sources: [gamepads](../scripts/test-gamepads.sh), [mouse pointer](../scripts/test-mouse-pointer.sh), [WinHTTP](../scripts/test-wine-proxy.sh), [remote presentation](../scripts/test-remote-presentation.sh), [MSync](../scripts/test-msync.sh).

## Component rebuilds

These commands **write new resources** and may download public source inputs. They are not prerequisites for building the app, and should not be run merely to validate documentation. Fixed timestamps do not guarantee identical binaries across different compilers/SDKs.

| Recipe | Required tools/inputs and outputs |
| --- | --- |
| [build-gamepad-bridge.sh](../scripts/build-gamepad-bridge.sh) | Python 3 and both MinGW GCC/strip toolchains; offline original-source build of the current MIT sources as a **new** component (default `COMPONENT=magicwine-xinput-v2`; refuses `magicwine-xinput-v1` and any existing output). Stages both DLLs, corresponding source, and a `LICENSE-<component>.txt` copy of the root license under gitignored `.local/gamepad-bridge-output/<component>/`; never touches `Sources/MagicWineCore/Resources` or the pinned v1 GPL payload. Prints hashes and the manual adoption steps (resources list, new Swift pins, notices, migration); does not update Swift pins. |
| [build-wow64cpu.sh](../scripts/build-wow64cpu.sh) | Python 3, shell archive/patch tools, x86_64 MinGW GCC/binutils. Fetches pinned public inputs unless using packaged offline inputs. Writes DLL/source/LGPL notice and prints hashes; does not update Swift pins. |
| [build-dxvk.sh](../scripts/build-dxvk.sh) | macOS, both MinGW toolchains, Meson, Ninja, glslang, Python 3, archive/patch tools. Fetches pinned source if uncached; builds six native D3D DLLs, not DXGI. Writes archive/provenance and retains build logs; Swift pins remain separate. |
| [build-metal-wine.sh](../scripts/build-metal-wine.sh) | Exact recorded Apple clang and fixed macOS 26.5 SDK, both MinGW GCCs, make/flex/Perl/Python and native inspection tools. Builds pinned Bison plus matched Wine modules/server. Writes compressed images, source, license, provenance; Swift pins remain separate. |
| [build-dxmt.sh](../scripts/build-dxmt.sh) | Python 3, Apple native tools/SDK, Meson/Ninja/CMake and recorded LLVM/MinGW inputs, Rosetta, exact tool lock and pinned Wine development inputs. Writes renderer/source/provenance and regenerates `DXMTRemoteBuildPins.swift`. |

Typical tool installation suggestions in the recipes are `brew install mingw-w64 python` for the bridge/CPU work and `brew install mingw-w64 meson ninja glslang python` for DXVK. These do not satisfy the exact Wine/DXMT toolchain locks by themselves. Read each recipe before installing or fetching anything.

The managed-Wine recipe currently requires `clang-2100.3.34.2` and `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`; it builds Bison 3.8.2 because Apple's old system Bison is insufficient. It can use the shipped corresponding-source inputs offline, but still requires the recorded external tools/SDK. It does not use `MAGICWINE_SDK`.

DXMT separates network provisioning, tool locking, and offline compilation:

```sh
bash scripts/build-dxmt.sh --fetch
bash scripts/build-dxmt.sh --lock-tools
bash scripts/build-dxmt.sh
```

These are separate stages. `DXMT_INPUTS` selects the input cache, `WINE_BUILD` selects the required development-input tree, and `JOBS` controls parallel compilation. The recipe deliberately requires pinned **metal.4 development inputs and source**, not an arbitrary installed Wine or the newest metal.7 output. Its corresponding-source archive preserves matching development inputs; external tools and separately provisioned prerequisites remain necessary. Locking different tools does not prove that their output matches shipped pins. Generated Metal shader arrays are extracted and verified from pinned upstream binaries; regenerating shaders is a different workflow requiring Apple's Metal compiler.

### Updating integrity contracts

See [Compatibility patches](compatibility.md) for the module map. For a real component update, coordinate:

- Source/patch identity, output architecture, runtime ABI, and any generated shared protocol.
- Binary and compressed-image digests, source archive, provenance, and license/notices.
- Compiled expectations in the owning installer and [Package.swift](../Package.swift) resource entries.
- Component identity and treatment of already installed receipts, original backups, and historical variants.
- Actual Windows execution and failure cases, not just successful compilation.

In particular, rebuilding today's MIT bridge source changes its source/license resources relative to the historical pinned GPL XInput v1 distribution. Merely changing `GamepadBridge.swift` pins can invalidate existing bottle backups. Treat it as a component compatibility change, not a notice cleanup. Never rewrite immutable third-party notices to match the root license.

## Evidence levels

| Check | Establishes | Does not establish |
| --- | --- | --- |
| Swift build and package inspection | Code compiles; required app/CLI resources and notices are present | Wine ABI compatibility or game behavior |
| Swift regression suite | Deterministic persistence/validation/transition contracts | Real Windows APIs or physical devices |
| Real Wine API probe | Selected runtime behavior for the exercised API and architecture | Every game uses that API or DLL |
| GPU readback and presentation probe | Rendered buffer contents and successful exercised presentation calls | Final window composition, visibility, or visual quality |
| Native/desktop interaction and physical devices | The observed UI/game/input path on that host | General compatibility or performance elsewhere |
| Bounded synchronization benchmark | Measured synchronization cost for that scenario | Game FPS improvements |

Record the exact app revision, Wine/component identities, host/GPU/OS, Windows architecture, settings, and evidence limits. Avoid fixed passing-test counts or hardware performance claims in this guide; those belong with a specific recorded verification run.
