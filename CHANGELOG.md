# Changelog

All notable changes to **Park Expansions** (`Mod_BoundaryLab`) are documented in this file.

## [0.52] - 2026-10-27

### Added
- **4096 × 4096 Map Support:**
  - Full support for 4K sandbox parks with buildable area up to **4088 × 4088 m** (with 4 m edge safety padding).
  - Isolated cache directory (`Maps4096`) so existing 2K saves retain their original size and performance.
  - Automatic 7-tier research tree progression for 4K maps (Tier VI: 3072 m, Tier VII: 4088 m).
  - Hook for `CommonObjectCreator.CreateEnvironmentCaptureGrid`: dynamically scales reflection probe density on 4K maps to prevent `fSymbolTable out of memory` engine crashes while providing uniform reflection coverage.
- **Native C++ Standalone Terrain Worker:**
  - Completely ported the terrain generator from Python/NumPy to an ultra-fast, native C++ standalone executable (`ParkExpansionsWorker.exe`, ~408 KB).
  - Dropped bundled Python 3.14 runtime and PyInstaller dependencies entirely.
  - Reduced overall release archive size from **23.3 MB down to 1.0 MB**.
  - 4K voxel generation and mipmap downsampling now finishes in ~30–60 seconds cold.
  - Eliminates Nexus Mods heuristic antivirus quarantine issues.
- **Dynamic Scenery & Backdrop Transfer:**
  - All backdrop vegetation, trees, and rocks from stock Sandbox templates across all four biomes (Temperate, Tropical, Taiga, Mediterranean) are now preserved and imported as editable, movable park scenery objects.
- **Extended Camera Zoom:**
  - Hooked Cobra engine camera system (`Components.Cameras.CameraModeManager` and `CameraLogic`) to extend standard orbit camera zoom distance limits.
  - Defaults to **2.5× further zoom (750 m)** on 4K maps and **2.0× (600 m)** on 2K maps.
  - Added `CameraZoomMultiplier` setting to `Config.ini` for manual customization.

### Fixed
- **Loading Bar Smoothness:** Fixed chunk traversal ordering (`Z -> Y -> X`) in octree generation, preventing the loading progress bar from oscillating backwards during cold generation.
- **Terrain Height Validation:** Transposed chunk ordering corrected and terrain verification table populated with integer coordinate keys, resolving stock contour height check mismatches.
- **Scenery Hash Validation:** Pre-generated SHA-256 decor payloads for stock OVL templates, eliminating scenery loading aborts.
