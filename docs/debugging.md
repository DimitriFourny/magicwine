# Debugging a game or launcher

[Documentation index](README.md) · [Runtime lifecycle](runtime-lifecycle.md) · [Development](development.md)

Start with an isolated reproduction and identify the failing layer before changing DLLs or system settings. A slow launcher, missing input, failed graphics device, and invisible presented window are different problems even if the same game exposes them.

## 1. Use a separate library

From the checkout, with the packaged CLI built:

```sh
CLI="$PWD/dist/magicwine"
ROOT="$PWD/.local/game-research"
"$CLI" --help
"$CLI" --root "$ROOT" list
```

`--root` must precede the command. An empty `list` prints no rows and creates only the selected library hierarchy; it does not download or launch Wine. Without `--root`, the CLI uses the normal `~/Library/Application Support/MagicWine` library. The CLI does not read the GUI's environment override.

To use the native app with the same root:

```sh
MAGICWINE_DATA_ROOT="$ROOT" ./dist/MagicWine.app/Contents/MacOS/MagicWine
```

Native startup discovers host Wine executables and monitors controllers. The data root isolates saved MagicWine state, not OS access. Windows programs still have your macOS user's privileges; a bottle is not a sandbox.

## 2. Choose and record the runtime

Use an executable you trust. `runtimes` discovers candidates and executes their `--version`; it is not a passive directory listing.

For managed Wine, review the unsigned-runtime implications before running:

```sh
"$CLI" --root "$ROOT" install-wine --accept-unsigned
```

This downloads or validates the pinned runtime and removes quarantine only within the validated managed app bundle. A checksum is not a malware assessment. The command prints the version and executable path; it does not change existing bottle pins or the GUI's preferred-runtime setting.

Create a bottle with that printed path, or a deliberately selected compatible custom runtime:

```sh
WINE="/absolute/path/to/wine/bin/wine"
"$CLI" --root "$ROOT" create "Game research" "$WINE"
"$CLI" --root "$ROOT" list
```

Creation prints a bottle UUID before initialization. If Wine setup fails, the saved bottle can remain uninitialized. Read the log and retry that same bottle with `initialize`; do not mistake the saved record for successful Windows setup.

For the remaining examples, replace the UUID below with a value from `list`:

```sh
BOTTLE="<bottle-UUID>"
"$CLI" --root "$ROOT" initialize "$BOTTLE"
```

Run `initialize` only when setup/retry is needed, not as an unexplained fix for every game failure.

## 3. Reproduce the same launch path

```sh
"$CLI" --root "$ROOT" install "$BOTTLE" "/absolute/path/to/installer.exe"
"$CLI" --root "$ROOT" refresh "$BOTTLE"
"$CLI" --root "$ROOT" apps "$BOTTLE"
```

MSI installers use the same `install` command with the `.msi` path. Manual launcher registration accepts an EXE, LNK, or URL shortcut:

```sh
"$CLI" --root "$ROOT" add "$BOTTLE" "/absolute/path/to/shortcut.url" "Research launcher"
"$CLI" --root "$ROOT" apps "$BOTTLE"
PROGRAM="<program-UUID>"
"$CLI" --root "$ROOT" launch "$BOTTLE" "$PROGRAM"
```

These are alternatives according to how the software is installed, not a mandatory sequence. Registration does not copy/install an executable. Discovery scans shortcut locations, not Steam's entire inventory or every EXE. URL shortcuts are dispatched through the bottle's registered Windows handler; a Steam URL does not intentionally launch macOS Steam. Local shortcut fields supply icon sources without a network icon fetch.

The same EXE with different arguments or working directory can represent a different launcher. Use the saved shortcut when reproducing a shortcut-specific failure instead of assuming direct EXE launch is equivalent. LNK/URL launch waits for the prefix server after asynchronous shell dispatch; EXE launch follows the direct process. Both may produce detached Windows children.

For a narrow Windows command probe:

```sh
"$CLI" --root "$ROOT" exec "$BOTTLE" cmd /c ver
```

`exec` forwards the remaining arguments as Wine arguments, without shell interpolation or a special `--` delimiter. On success it prints the process log. The runtime gives child processes null stdin, so this is not an interactive Windows terminal.

Source: [Main.swift](../Sources/MagicWineCLI/Main.swift), [WineRuntime.swift](../Sources/MagicWineCore/WineRuntime.swift), [WindowsShortcut.swift](../Sources/MagicWineCore/WindowsShortcut.swift).

## 4. Inspect the right evidence

The native bottle's **Reveal Logs** action opens the library logs. For an isolated CLI run, inspect `"$ROOT/Logs"`.

| Location under the data root | Evidence |
| --- | --- |
| `Logs/wine-install-<UUID>.log` | Download source/version/hash, driver preparation, publication/quarantine steps, install failure |
| `Logs/wine-version-<UUID>.log` | Executed runtime and reported version |
| `Logs/<bottle-UUID>-wine-<UUID>.log` | Command and combined Windows/Wine stdout/stderr |
| `Logs/<bottle-UUID>-wineserver-<UUID>.log` | Prefix-scoped stop/wait operations |
| `Logs/<bottle-UUID>-not-started-<UUID>.log` | A requested Stop prevented a pending process from starting |
| `Logs/<bottle-UUID>-dxvk/`, `Logs/<bottle-UUID>-dxmt/` | Backend output where provided |
| `Bottles/<UUID>/bottle.json` | Pinned runtime, saved launchers, selected component, display/synchronization preferences |
| `Bottles/<UUID>/graphics/` | Active originals, transaction/recovery state, and renderer caches |
| `Bottles/<UUID>/runtime-compatibility/` | CPU/XInput original backups and matching source/notices |

Process logs start with the command/arguments, followed by any `Warning:` lines for launch integrations that were skipped (controller bridge or Rosetta CPU repair); the complete environment is not logged. File modes restrict ordinary access but do not prevent secrets or personal paths appearing in application output. CLI errors use exit status 1 and print a diagnostic; that is not necessarily the Windows child's numeric exit code.

The presence of a backend log or cache directory does not prove the game reached a rendered frame. D3DMetal does not get the same dedicated backend log path from this implementation.

### Environment overrides are controlled

MagicWine strips inherited Wine/loader and graphics variables and reconstructs its launch environment. In particular, `WINEDEBUG=... magicwine exec ...` is not a supported way to retain a diagnostic override, and inherited `DXVK_*`, `DXMT_*`, `D3DM_*`, `MTL_*`, and `DYLD_*` values are not authoritative.

If deeper logging requires a source change, make that explicit in the research checkout and record it. A direct raw-Wine invocation bypasses MagicWine's preparation and can be a useful comparison only in a disposable prefix; it is not an equivalent reproduction of managed graphics/controller/runtime behavior. Do not manually modify a production bottle's overrides to force a diagnostic result.

Sources: [ProcessOperation.swift](../Sources/MagicWineCore/ProcessOperation.swift), `environment` in [WineRuntime.swift](../Sources/MagicWineCore/WineRuntime.swift).

## 5. Narrow the failing layer

| Symptom | First distinction | Next evidence |
| --- | --- | --- |
| Wine cannot start or setup times out | Missing executable/adjacent server, Rosetta, Gatekeeper, or incomplete layout versus Windows failure | Version/install log and exact pinned path; retry managed install only after reviewing consent |
| UI says Running after closing a launcher window | Tray-hidden or detached Windows process versus hung management operation | Exit the launcher normally; use prefix-scoped Stop when appropriate |
| No game appears in the library | Missing Windows shortcut versus failed installation | Start Menu/Desktop contents, Refresh, or Add Program; Steam inventory is not scanned |
| Game exits before creating a graphics device | Loader/CPU/TLS/dependency failure versus rendering failure | Command log, Windows architecture, selected runtime revision; [Compatibility patches](compatibility.md) |
| Backend selection fails | ABI/host requirements or missing component versus game compatibility | Exact setup error and [Graphics](graphics.md); do not copy one DLL to bypass it |
| Blank foreign-process window | Producer render failure versus owner/compositor presentation | Remote-presentation probe with the same backend/HUD state and separate visual inspection |
| Steam/network update stalls | Proxy autodiscovery versus DNS/TLS/HTTP or launcher rendering | WinHTTP runner and host proxy policy; avoid global proxy/DNS/certificate changes |
| Mouse absent in a modern engine | Mouse-in-pointer versus raw/classic input or capture | Pointer runner on the pinned managed runtime; not merely a rebuilt app |
| Native controller preview works but game does not | Physical discovery versus saved profile or selected Windows DLL/API | Save Changes, inspect actual XInput selection; preserved Microsoft/game-local DLLs may bypass bridge |
| MSync selection unavailable | Old/custom pinned runtime versus missing app toggle | Current managed identity and explicit adoption, not just Wine version text |
| MSync client fails at startup | Client/server mode or protocol mismatch | Server marker and paired modules; stop the bottle rather than mixing `ntdll`/server versions |
| Component/backup integrity error | Modified or missing data versus a normal cache miss | Preserve receipt/backups/logs and compare to compiled expectations; do not rewrite receipts to bless bytes |

The focused runner syntax and prerequisites are in [Development](development.md). They operate on temporary prefixes; a passing runner narrows the problem but does not establish the game's complete compatibility.

## Running, stopping, and changing settings

A launcher window closing is not the same as Wine exiting. MagicWine permits additional launches while tracked launch tasks remain active; exclusive UI operations are separate. UI status is not a complete inventory of children or other frontend processes.

```sh
"$CLI" --root "$ROOT" stop "$BOTTLE"
```

Stop cancels pending/tracked work and asks the bottle's own `wineserver` to terminate and wait. It is not a system-wide `pkill wine`. **Save game state first.** Configuration has different contracts:

- Synchronization changes and runtime adoption require an idle bottle and reject detached live servers without killing them.
- Explicit core/CLI graphics and Retina changes can stop the bottle. The native UI applies additional activity guards.
- Automatic adoption of display defaults never terminates a live game just to update DPI.

For inspection without changing settings:

```sh
"$CLI" --root "$ROOT" graphics "$BOTTLE"
"$CLI" --root "$ROOT" retina "$BOTTLE"
"$CLI" --root "$ROOT" synchronization "$BOTTLE"
```

For experiments, vary one setting at a time and retain a baseline. [Graphics](graphics.md) documents consent flags, Standard restoration, and backend limitations. MSync on/off comparisons require the paired patched runtime and a stopped bottle; timing differences alone do not establish a game-FPS improvement.

## App rebuild versus runtime update

A Swift launch-policy fix may only require rebuilding and restarting the app/CLI. A change to the native driver, mouse-pointer implementation, WPAD, or MSync requires the matching rebuilt managed runtime. A renderer patch additionally requires its matching graphics component.

The GUI bottle **Update Wine** flow installs/reuses and then adopts. The CLI keeps those actions explicit:

```sh
"$CLI" --root "$ROOT" install-wine --accept-unsigned
"$CLI" --root "$ROOT" stop "$BOTTLE"
"$CLI" --root "$ROOT" runtime upgrade "$BOTTLE"
```

This upgrade only applies to eligible older managed Metal runtimes, not arbitrary custom Wine. Installation alone does not repin a bottle. Existing files/runtime pins are retained when adoption fails. Changing a graphics component is a separate contract; do not assume a Wine upgrade also replaces an old DXMT selection.

## Recovery without destroying evidence

Do not delete `graphics/transaction`, original backups, or notices to bypass validation. The journal's before/after metadata determines recovery direction; deleting it can remove the information needed to restore files safely. A fresh separate bottle is preferable to speculative repairs of a valuable one.

Standard graphics can restore a valid original footprint even if the previously selected component is unavailable. Unknown user-replaced managed DLLs are preserved during supported switching/restoration. Invalid backups still fail closed. Missing/corrupt cached runtime installations are not automatically repaired in place.

Removing a program only removes its launcher record. **Trash Bottle** moves the entire UUID-owned Windows environment to macOS Trash after Stop; external registered executables, shared runtimes, and separate library logs are not its deletion target. The CLI has no bottle-delete command. Avoid racing deletion against another frontend's launch.

## Reporting useful results

Include:

- MagicWine commit/build, macOS version, CPU/GPU, Rosetta availability, and Windows executable architecture.
- Exact Wine executable identity and component revisions, with personal path portions redacted.
- Installation source/game version and the actual launch path: EXE, LNK, URL, launcher, or integration probe.
- Backend, HUD, Retina/DPI, MSync, and relevant controller profile state.
- Small reproduction steps, expected versus observed behavior, and whether a fresh isolated bottle changes the result.
- Relevant log excerpts and the earliest meaningful failure, not only the final crash or timeout.
- What was actually observed: process exit, API result, GPU readback, visible window, controller input, or physical vibration.

Review logs, screenshots, command arguments, and paths before sharing. Remove account names, tokens, private URLs, and unrelated application output. Do not upload a game installation, personal prefix, or proprietary D3DMetal/CrossOver libraries as a bug-report attachment. Successful startup or one frame is not proof of sustained gameplay or performance.
