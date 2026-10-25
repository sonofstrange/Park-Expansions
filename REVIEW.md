# Executable components and Nexus review

This document describes the 0.45-test source and package; it is not an antivirus certification.

## ParkExpansionsBridge.dll

Source: [`work/compatibility/bridge.cpp`](work/compatibility/bridge.cpp).

Loaded through Lua `package.loadlib`. Reads four Lua string arguments using a read-only, version-gated reader with Windows structured exception handling. Checks the host PE timestamp and image size before enabling conversion. It does not patch the game executable or call game code addresses. It launches the bundled worker hidden through `CreateProcessW`, and exchanges progress/results with Lua through files under the mod's `AutoConversion` directory.

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
