# Compiled component and Nexus review

This document describes the **0.57** source and distribution. It is not an antivirus certification.

## Archive contents

The ZIP contains four files under `Mod_BoundaryLab/`:

- `Main.ovl`: compiled Lua and the mod UI.
- `Manifest.xml`: game mod registration.
- `Config.ini`: default settings, using Lua syntax.
- `Compatibility/ParkExpansionsBridge.dll`: the native bridge and integrated terrain/scenery generator.

No EXE worker, Python runtime, nested ZIP, generated map, player save, diagnostic log or test binary is distributed.

## DLL source and runtime behavior

Sources are `work/compatibility/bridge.cpp`, `sea_raster.h`, `sea_raster_plan.h`, `navigation_bounds.h`, `crowd_grid.h` and `miniz.c` / `miniz.h`. Build steps are in [BUILD.md](BUILD.md). File hashes are published in [release-manifest.json](release-manifest.json).

Lua loads the DLL through `package.loadlib`. A version-gated reader receives string arguments. The bridge starts an internal background thread for terrain/scenery preparation and exchanges progress/results with Lua through local files. It reads original installed Sandbox and biome assets and writes generated cache data under the mod's Maps/Maps4096 and AutoConversion directories. The current native request dispatcher implements terrain preparation, startup configuration, boundary-size synchronization and diagnostics; legacy existing-save conversion is not a validated feature of this release. The game handles normal park saving.

The generator uses bundled miniz code for compression and Windows Cryptography APIs for hashes. It does not launch an external worker, download assets, access credentials or send telemetry. No network requests are implemented by the mod-specific source.

## In-process game changes

The DLL modifies game code in memory for the supported executable build, **1.11.3.986758**. It does not write the game EXE on disk.

- Sea raster: 38 immediate operands coordinate CPU buffers, centering, row strides, GPU texture dimensions and shader size values.
- NavigationWorld initializer: two vector-load displacements point to private bounds constants covering +/-2048 m.
- CrowdSimulation shared grid: one scalar-load displacement changes the width passed to both grid axes from 1024 to 4096 m. The original initializer and coordinate lookup derive the new dimensions.
- Park boundary test: a detour/trampoline calls the original function, then permits positions inside the configured expanded bounds. An unrelated detour at that location is rejected rather than reported as this mod's hook.

The bridge checks the executable timestamp/image size and original instruction bytes. The Sea, NavigationWorld and CrowdSimulation changes also validate complete function fingerprints before patching. New private bounds constants are read-only, and RIP-relative allocation searches both address directions. Code changes use VirtualProtect and FlushInstructionCache. Initialization errors are exposed through Copy Report and BridgeDebug.log. Navigation/Crowd failures retain their stock domains without aborting an otherwise supported terrain load.

These memory changes and the compiled DLL may trigger antivirus or hosting-site review even though the separate EXE worker has been removed. No claim of guaranteed scanner acceptance is made.

## Validation and limits

The user confirmed guest travel beyond the original map boundary in 0.56-crowd-test. Private-memory native tests verify the original and extended bounds and the Crowd coordinate rejection/acceptance behavior. Lua tests cover research, geometry, loading, scenery and configuration. Native test exports are compiled only with BRIDGE_TEST and are absent from the release DLL.

The Crowd test stubs unused bucket storage allocation; it is not a full simulation or GPU-memory test. Existing-save compatibility, repeated save/reload and all biome combinations have not been comprehensively verified. The mod remains experimental.

For a Nexus review, supply the mod page, the exact release tag/source commit and BUILD.md. A quarantine notice alone does not identify the responsible file or scanner rule.
