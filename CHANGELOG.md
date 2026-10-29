# Changelog

All notable changes to **Park Expansions** (`Mod_BoundaryLab`) are documented in this file.

## [0.60] - 2026-10-29

### Fixed
- Fixed existing-save conversion selecting a different biome template from the park's original boundary. The reported Mediterranean park could retain its backdrop while receiving Tropical outer terrain and scenery, then fail boundary expansion.
- The converter now identifies the ParkBoundary type through each save's string table, verifies its original contour, and keeps the source boundary coordinates instead of substituting hardcoded seed coordinates.
- Added a conversion cache revision so older incorrect cached conversions are not reused. Manual cache deletion is not required.
- Already-converted parks with a mismatched template now stop before changing the boundary and show instructions to retry from the original pre-conversion backup.

### Validation
- The bug reporter confirmed the fix in-game.
- Native tests cover all four stock biome contours, source boundary elevation, save-local type IDs, and rejection of unsupported or malformed contours.

### Notes
- To retry a previously incorrect conversion, use the original save or its pre-conversion backup. Existing incorrect outer terrain is not automatically rebuilt.
- Guest pathfinding issues in expanded areas remain under investigation.

## [0.59] - 2026-10-29

### Fixed
- Ctrl+Z no longer reverses a successfully applied park boundary expansion. The completed expansion becomes the new undo/redo baseline, keeping the boundary consistent with purchased research.
- Failed and diagnostic expansion attempts leave undo history unchanged.

### Behavior change
- Successful boundary changes clear previous undo and redo history. Construction performed after expansion can still be undone normally.
- Added an English notice in the research and manual configuration panels explaining the history reset.

### Validation
- The user confirmed the fix in-game. All 14 Lua test modules and native regression checks pass.

### Known issues
- Guests may still get stuck or take detours in expanded areas, including at ride queue entrances.
- Existing-save conversion remains experimental. Back up saves before use.

## [0.58] - 2026-10-29

### Fixed
- Save lookup now selects the most recently active local Steam profile first and searches only within that profile. A matching park in another account is no longer used as a fallback.
- Restoring background scenery in Challenge mode no longer leaves the player charged for imported decorations. The original unlimited-cash setting is restored immediately after the placement call, including when placement fails.

### Added
- `ConvertExistingSaves` config option to turn automatic existing-save conversion on or off.
- Windows DLL metadata identifying sonofstrange as the developer, with file and product version 0.58.0.0.
- Regression tests for profile selection, scenery refunds, and restoration of the original cash mode.

### Known issues
- Ctrl+Z can still undo a park boundary expansion while its research unlock remains recorded. Reapplying after undo has previously caused a crash and needs further investigation.
- Guests can cross the original boundary, but may still get stuck or take detours in expanded areas, including at ride queues.
- Existing-save conversion remains experimental. Keep a backup before testing.
- DLL metadata does not guarantee that antivirus software will stop flagging the mod.

## [0.57] - 2026-10-28

### Fixed
- **Undo / Redo Crash on Expansion:**
  - Removed explicit boundary expansion and scenery restoration checkpoints. This did not remove native placement transactions from undo history; Ctrl+Z can still undo an expansion (see the 0.58 known issues).
  - Hardened contour probing against dangling/null pointers after undo operations; invalid or missing posts/panels fall back safely to the stock biome template instead of causing an Access Violation crash.
  - Added automatic resynchronization to stock bounds if boundary points match the biome baseline after an undo.
- **Scenery Edit and Delete Locks:**
  - Fixed an issue where scenery objects near the former boundary and restored background decor could not be edited or deleted (`deleteEnabled = false` due to `partSet:CanEdit() == false`).
  - Automatically clears edit constraints across all scenery parts, rides, flumes, and coaster tracks (`ClearEditConstraintsForAllParts()`, `SetAllRidesEditable(true)`, `ClearAllTrackEditConstraints()`, `SetAllPlatformsEditable(true)`) upon expansion, save loading, and scenery placement.

### Added
- **Automatic Save Backup System:**
  - When loading a previously unmanaged/vanilla park for the first time, the mod automatically creates a backup of the original `.park2` save file before any conversion or expansion occurs.
  - Backups are stored as `<SaveName>-<ID>.park2.bak` alongside the original save, and also saved into `Saved Games/Frontier Developments/Planet Coaster 2/<SteamID>/Saves/ParkExpansions_Backups/` for safe recovery.

### Known issues
- Pathfinding in expanded areas: guests can walk past the vanilla boundary, but ride queue entrances and route selection in expanded territory can exhibit detours or strange routing. Investigation ongoing.

## [0.56] - 2026-10-28

### Fixed
- Guests can now walk beyond the original map boundary and follow paths in expanded park areas, instead of turning back at the vanilla limit.
- Extended the crowd navigation grid used by guests and facility path connections to cover 4096 x 4096 m parks.
- Fixed nearby-memory allocation failing when no suitable address was available above the game code.
- A navigation setup failure now reports its cause without aborting an otherwise supported terrain load.

### Known issues
- Pathfinding outside the original map boundary may still be unreliable. Crossing the old boundary now works, but route selection and navigation in expanded areas need further investigation.

### Diagnostics
- Added `BridgeDebug.log` and navigation/crowd-grid status to **Copy Report**.

Guest movement beyond the original boundary has been confirmed in-game by the user. Save/reload behavior across all supported biomes has not been comprehensively tested.

## [0.53] - 2026-10-28

### Highlights (0.51 -> 0.53)
- **No Separate EXE Worker:**
  - Completely eliminated all external `.exe` binaries (`ParkExpansionsWorker.exe`) from the mod distribution.
  - The entire terrain voxel generator, octree encoder, and mipmap downsampler now execute inside a native asynchronous background worker thread within `ParkExpansionsBridge.dll`.
  - No external worker process or bundled Python runtime. The mod still contains compiled DLL code and may require antivirus or hosting-site review.
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
