# Executable components and Nexus review

This document describes the 0.51-test source and package; it is not an antivirus certification.

## ParkExpansionsBridge.dll

Source: [`work/compatibility/bridge.cpp`](work/compatibility/bridge.cpp).

Loaded through Lua `package.loadlib`. Reads four Lua string arguments using a read-only, version-gated reader with Windows structured exception handling. Checks the host PE timestamp and image size before enabling conversion. It launches the bundled worker hidden through `CreateProcessW`, and exchanges progress/results with Lua through files under the mod's `AutoConversion` directory.

**0.50-test introduced an in-process code modification for 4K maps, retained unchanged in 0.51-test.** The startup request adjusts 38 immediate operands in two native Sea heightmap routines in game build 1.11.3.986758. Sources: [`sea_raster.h`](work/compatibility/sea_raster.h) and [`sea_raster_plan.h`](work/compatibility/sea_raster_plan.h). Full-function fingerprints and exact original instruction bytes must match before any write. The changes coordinate CPU allocations, dimensions, centering, row strides, GPU texture dimensions and shader size/reciprocal values. It temporarily changes page protections through `VirtualProtect`, restores them and flushes the instruction cache. It does not install detours, call game code addresses, modify protected/packed code or write the game EXE on disk.

Initialization runs when the mod database loads, before park managers are created. The enlarged Sea raster remains active for the process, including subsequent smaller parks. A missing/mismatched component blocks 4K loading; a new park can load its original template. Loading an existing 4K save is stopped rather than passing its oversized data to the unmodified Sea routine. This is an experimental native fix; offline checks do not establish in-game compatibility. Unlike the published 0.35 release, this test DLL changes executable memory and may receive additional scanner scrutiny.

## ParkExpansionsWorker.exe

Sources: [`generate_maps.py`](work/compatibility/generate_maps.py), [`stock_terrain.py`](work/compatibility/stock_terrain.py), [`terrain_transition.py`](work/compatibility/terrain_transition.py), [`auto_convert.py`](work/compatibility/auto_convert.py), [`convert_park.py`](work/compatibility/convert_park.py), [`terrain_codec.py`](work/compatibility/terrain_codec.py).

A PyInstaller onedir executable bundling CPython. Resolves the Windows Saved Games known folder, reads supported local Planet Coaster 2 saves and the generated terrain cache, and writes converted copies and progress files under the mod's `AutoConversion` cache. Conversion validates the terrain format and preservation of existing voxel roots. The source save is retained; the native load request is redirected to the converted cache before world loading. Normal saving after loading is handled by the game.

The mod-specific bridge and worker source does not implement downloads, telemetry, credential access or network requests. The bundled interpreter/runtime contains standard library functionality; its presence does not mean that every bundled module is used by this mod.

## Archive contents

The distribution includes an EXE, a DLL, Python DLLs/extensions and `_internal/base_library.zip`. These may trigger an executable or nested-archive review. The Python ZIP is required by the frozen interpreter and must not be removed without changing and testing the worker packaging.

Build steps: [BUILD.md](BUILD.md). Published file hashes: [release-manifest.json](release-manifest.json).

For Nexus moderation, provide the mod page link, this repository and the exact release/version being reviewed. A quarantine notice alone does not identify which file or scanner rule triggered it.

## First-use terrain generation

The worker now also accepts a `__prepare_map__` request from the Lua bridge. It resolves the installed game's root from the fixed mod directory layout, reads the selected biome's original Sandbox/landscape assets, creates a 2048 m map and underlay pair, and verifies preservation of source voxel data. It uses NumPy for height/material sampling. The source game files are never modified. Generated maps, per-biome validation probes and checksummed generation manifests are written under `Mod_BoundaryLab/Maps`. Converted saves and immutable progress/result files remain under `AutoConversion`.

NumPy's license notices are included with the frozen runtime. The generated files are not bundled in the smaller download. Existing 0.35 reference maps in this source repository are only regression fixtures for this branch.

## Scenery preservation in 0.43

`stock_scenery.py` reads only the selected original biome-world OVL with a bounded, layout-checked ZLIB reader. It writes a checksummed `.decor.lua` cache and manifest under `Maps`. `boundarylab.scenery.lua` imports those transforms as native editable scenery parts during loading. A new `ParkExpansionsScenery` serialization client records completion; the native placement clients save the actual objects. Generation does not modify the original world OVL, source parks, terrain files or saves.


## 0.51 capture-grid budget

The 0.50 manual test passed the previous Sea crash location and terminated later with `fSymbolTable out of memory or IDs` while creating `CapturePoint_CurrentSpecular_3709`. The stock CPTWorld loader creates an environment reflection grid with a fixed 60 m distribution radius over the full voxel bounds. Its staggered layout produces 5265 capture points for the 4095 m span, versus 1306 for the working 2047 m span.

The Lua hook on `CommonObjectCreator.CreateEnvironmentCaptureGrid` scales that radius by `max(1, span / 2048)` only for the 4096 m profile. Full bounds, height, native completion token, result entities and stock cleanup are preserved. It also scales each point's native coverage radius through the original creator. The 4K grid then has 1306 points. No additional native code changes, symbol-table edits, resource-name reuse, terrain changes or save-format changes are involved. `Copy Report` includes the actual span, distribution radius and point count. In-game validation of 0.51 is pending.
