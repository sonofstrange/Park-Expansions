# Changelog

All notable changes to **Park Expansions** (`Mod_BoundaryLab`) are documented in this file.

## [0.53] - 2026-10-28

### Highlights (0.51 -> 0.53)
- **Zero .EXE Architecture (No Executables):**
  - Completely eliminated all external `.exe` binaries (`ParkExpansionsWorker.exe`) from the mod distribution.
  - The entire terrain voxel generator, octree encoder, and mipmap downsampler now execute inside a native asynchronous background worker thread within `ParkExpansionsBridge.dll`.
  - Zero antivirus false positives, zero external process spawning, clean and safe mod footprint.
- **Zero Hardcoded Decor Coordinates (Dynamic Extraction):**
  - Completely eliminated all bundled static coordinate tables (`.decor.lua` / `.decor.json`) from the release package.
  - Backdrop scenery (trees, rocks, vegetation) is now parsed and extracted dynamically on-the-fly from the local game assets (`Content0/Worlds/...` and `.bakedHeightMap`) on demand when preparing a park.
- **Ultra-Compact Mod Size (243 KB):**
  - Mod distribution now consists of only **4 files** (`Config.ini`, `Main.ovl`, `Manifest.xml`, `Compatibility/ParkExpansionsBridge.dll`).
  - Total package size reduced from 1.0 MB (in 0.51) down to just **243 KB** (and down 100× from the original 23 MB Python build).

### Added & Improved
- **Extended Camera Zoom:**
  - Integrated hooks into the Cobra engine camera system (`Components.Cameras.CameraModeManager` and `CameraLogic`).
  - Extends standard orbit camera zoom range by 2.0×–2.5× (600–750 m instead of stock 300 m).
  - Fully configurable via `CameraZoomMultiplier` in `Config.ini`.
- **Scenery Cluster Prefab Engine Integration:**
  - Added explicit 3D mesh model mapping (`clusterModels`) for backdrop clusters across all biomes (Mediterranean, Taiga, Tropical, Temperate).
  - Implemented precompilation (`ensureCompiled`) of parent stock gameplay prefabs (`NAT_Tree_*_Large_01_Game`) before registering custom cluster prefabs.
  - Dual registration in both `package.loaded` and `package.preload` with exact and lowercase casing to ensure full ACSE module loader compatibility.
  - Safe fallback to the stock base tree if a cluster model is missing in native storage, preventing any scenery restoration aborts.
- **Save File & Client Parsing Fixes:**
  - Resolved `Invalid game save format` by properly distinguishing raw zlib compressed streams from container headers in `unpack_game_save`.
  - Resolved `Unexpected scalar tag` in `ParkExpansionsBridge.dll` by correctly locating the `ClientSizes>` block before parsing client chunks.
- **Test Suite Verification:**
  - Full automated Lua test suite (14 test modules covering terrain bounds, auto-conversion, bridge events, scenery lifecycle, 4K grids, and camera zoom) passes cleanly.

---

## [0.51] - 2026-10-27

### Added
- **4096 × 4096 Map Support:**
  - Support for 4K sandbox parks with buildable area up to **4088 × 4088 m**.
  - Isolated cache directory (`Maps4096`).
  - Automatic 7-tier research tree progression for 4K maps.
  - Reflection probe density scaling on 4K maps to prevent `fSymbolTable out of memory` crashes.
- **Native C++ Standalone Terrain Worker:**
  - Initial port of terrain generator to standalone `ParkExpansionsWorker.exe`.
- **Dynamic Scenery & Backdrop Transfer:**
  - Preservation of backdrop vegetation across all four biomes.
- **Extended Camera Zoom:**
  - Initial camera zoom expansion hooks.

### Fixed
- **Loading Bar Smoothness:** Fixed chunk traversal ordering in octree generation.
- **Terrain Height Validation:** Corrected chunk ordering and terrain verification table keys.
