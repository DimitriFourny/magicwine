# License scope and bundled components

The root `LICENSE` applies to MagicWine's current original source and documentation, except files carrying an explicit different license. It does not relicense third-party code, Wine-derived patches, previously released artifacts, game artwork shown in screenshots, or locally imported software. Existing copyright and attribution notices remain applicable.

## Bundled resources

In this repository, the notices and archives below are in `Sources/MagicWineCore/Resources/`. In app distributions they are in `Contents/Resources/MagicWine_MagicWineCore.bundle/Contents/Resources/`; in CLI distributions they are in the adjacent `MagicWine_MagicWineCore.bundle/Contents/Resources/`.

| Component | Terms and accompanying material |
| --- | --- |
| Wine Metal runtime and WoW64 CPU repair | LGPL-2.1-or-later. See `LICENSE-WINE-METAL.txt` and `LICENSE-WINE-WOW64CPU.txt`. Matching `winemac-*-source.tar.gz` and `wow64cpu-*-source.tar.gz` archives preserve corresponding source, patches, build recipes, and upstream attribution. |
| DXMT | MIT for DXMT itself; dependencies retain their own licenses. See `LICENSE-DXMT.txt`, `dxmt-v0.80-remote.1-source.tar.gz`, and its provenance JSON. The original upstream runtime archive is also retained. |
| DXVK macOS fork | zlib/libpng for DXVK; dependency terms are in `LICENSE-DXVK-DEPENDENCIES.txt`. The runtime archive contains `LICENSE`; installation adds upstream/fork attribution and source/provenance links. The rebuild recipe is `scripts/build-dxvk.sh`. |
| Previously built MagicWine XInput v1 | The checked-in DLLs and `magicwine-xinput-v1-source.tar.gz` retain GPL-3.0-or-later, with the full license in `LICENSE-MAGICWINE-GAMEPAD.txt`. Current bridge source under `Sources/GamepadBridge/` is MIT. The pinned historical payload, source archive, and license are unchanged so existing bottle integrity checks remain valid. |

The historical DXVK dependency notice refers to GPLv3 in “MagicWine's LICENSE.” Since the project's MIT change, the full GPLv3 text remains available in `LICENSE-MAGICWINE-GAMEPAD.txt` in the same resource bundle as that notice. Its GCC Runtime Library Exception remains in `LICENSE-DXVK-DEPENDENCIES.txt`. The old wording is retained because installed components validate the exact notice bytes.

Wine-derived patches and files explicitly marked LGPL retain that license. Preserve all applicable notices and corresponding-source materials when redistributing bundled components; the root MIT license alone does not cover an app distribution containing them.

## External software

The full Wine distribution is downloaded separately from [Gcenx's macOS Wine builds](https://github.com/Gcenx/macOS_Wine_builds) and retains its upstream terms. Wine and CodeWeavers source attribution is preserved in the component notices and source archives.

D3DMetal, CrossOver, Rosetta, games, and other locally installed software are not licensed by this repository. D3DMetal is imported locally, not redistributed here, and remains subject to its owner's terms. Research references and proprietary application binaries in the ignored `references/` directory are not part of this repository. Product names and game artwork belong to their respective owners; their appearance does not imply affiliation or endorsement.
