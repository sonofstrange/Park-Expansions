# Changelog

All notable changes to **Park Expansions** (`Mod_BoundaryLab`) are documented in this file.

## [0.52] - 2026-10-27

### Added
- **Extended Camera Zoom:**
  - Hooked Cobra engine camera system (`Components.Cameras.CameraModeManager` and `CameraLogic`) to extend standard orbit camera maximum zoom distance.
  - Allows zooming out 2.0×–2.5× further (up to 600–750 m instead of stock 300 m).
  - Configurable via `CameraZoomMultiplier` in `Config.ini`.
- **Integrated In-DLL Background Generator (Zero .EXE Architecture):**
  - All terrain octree generation, mipmap downsampling, and voxel encoding are embedded directly into `ParkExpansionsBridge.dll` running on a native asynchronous background worker thread.
  - Completely eliminated all `.exe` executables, subprocess spawning, and bundled Python runtimes.
- **Dynamic On-the-Fly Scenery Extraction (Zero Hardcode):**
  - Backdrop vegetation, trees, and rocks from stock Sandbox templates are now parsed and extracted dynamically from the player's own local game files (`Content0/Worlds/...` and `TerrainSkirts/...`) on demand when preparing a park.
  - Completely eliminated all pre-generated hardcoded coordinate tables (`.decor.lua` / `.decor.json`) and pre-baked map caches from the mod distribution.
- **Ultra-Lightweight Mod Footprint:**
  - The entire mod distribution now consists of only **4 clean files** (`Config.ini`, `Main.ovl`, `Manifest.xml`, `Compatibility/ParkExpansionsBridge.dll`).
  - Total release zip archive size reduced to **234 KB** (down 100× from the previous 23.3 MB!).
