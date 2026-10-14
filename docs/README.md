# Technical documentation

MagicWine is a research tool for investigating specific Windows games on macOS, not a general compatibility guarantee. For everyday use, prefer [CrossOver](https://www.codeweavers.com/crossover). For the shortest build/start instructions, see the [project README](../README.md).

These guides describe the checked-in implementation. Source links identify the owning code; the [changelog](../CHANGELOG.md) records historical work and observations, not a current support matrix.

## Guides

| Guide | Questions it answers |
| --- | --- |
| [Architecture](architecture.md) | How do the native app, CLI, core library, Wine processes, and stored data fit together? What is and is not isolated? |
| [Runtime lifecycle](runtime-lifecycle.md) | How is Wine installed and trusted? What happens during bottle creation, launch, stop, and runtime adoption? |
| [Graphics](graphics.md) | Which path translates a game's graphics calls? How are components selected, validated, backed up, and restored? |
| [Compatibility patches](compatibility.md) | Which changes live in Wine/DXMT/DXVK versus Swift launch policy? What must be rebuilt together? |
| [Controllers and XInput](controllers.md) | How do physical input, saved profiles, shared memory, Windows DLLs, and vibration interact? |
| [Debugging](debugging.md) | How can a failure be reproduced in an isolated library and narrowed to the right layer? |
| [Development and verification](development.md) | How do builds, resource packaging, test runners, and component rebuilds work? What evidence does each check provide? |

Start with **Architecture** when changing the application. Start with **Debugging** when investigating a game. Read **Graphics** before changing DLL overrides, and **Compatibility patches** before rebuilding a runtime module.

## Vocabulary

| Term | Meaning here |
| --- | --- |
| Application data root | MagicWine's library of bottle metadata, Wine runtimes, components, settings, and logs; distinct from the source checkout |
| Bottle | One saved Windows environment, with its own Wine prefix and pinned executable path |
| Prefix | Wine's Windows filesystem and registry for a bottle |
| Managed Wine | The specific Wine distribution MagicWine installs and validates with its bundled compatibility payloads |
| Custom Wine | An explicitly selected external executable; managed-runtime assumptions do not automatically apply |
| Component | A separately identified graphics or compatibility payload with its own provenance, license, and integrity checks |
| Private runtime view | An application-root-owned loader/dependency layout for a particular Wine/component combination; not a replacement for the user's original Wine installation |
| Corresponding source | Source, patches, recipes, and other required inputs accompanying a distributed component; not disposable build output |

## Reading diagrams and evidence

Diagrams use Mermaid, rendered by GitHub without custom fonts or image-generation steps. In viewers without Mermaid support, the fenced text remains available. Diagrams show ownership and control/data flow, not measured timing.

A passing filesystem test does not establish Wine compatibility. A Windows API probe does not establish that a game loads the same implementation. GPU readback does not establish correct final window composition. See [verification levels](development.md) before treating a successful check as a compatibility claim.

## Boundaries that matter

- **A bottle is not a security sandbox.** Windows software runs with the macOS user's permissions, and Wine may expose host files.
- **An integrity hash is not a publisher signature or malware assessment.** Managed Wine installation requires explicit unsigned-runtime consent.
- **Existing runtime pins and backups are contracts.** Replacing one DLL, notice, or source archive can invalidate an installed component.
- **The root MIT license does not relicense bundled dependencies.** See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md); preserve matching source and license materials.
- **Proprietary imports stay local.** D3DMetal is not redistributed by this repository, and its use remains subject to its own terms.

## Keeping the guides accurate

When changing a persisted field, command, component identity, launch policy, or patch, update the relevant guide in the same change. Prefer links to implementation files over duplicated hash lists or fixed test counts. Record what was actually exercised, the runtime/component used, and any visual or hardware verification limits.
