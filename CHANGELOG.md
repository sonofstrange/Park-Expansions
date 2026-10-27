# Changelog

All notable changes to **Park Expansions** (`Mod_BoundaryLab`) are documented in this file.

## [0.52] - 2026-10-27

### Added
- **Extended Camera Zoom:**
  - Hooked Cobra engine camera system (`Components.Cameras.CameraModeManager` and `CameraLogic`) to extend standard orbit camera maximum zoom distance.
  - Allows zooming out 2.0×–2.5× further (up to 600–750 m instead of stock 300 m).
  - Configurable via `CameraZoomMultiplier` in `Config.ini`.
- **Native C++ Standalone Terrain Worker:**
  - Completely ported the background terrain worker from Python/NumPy to a native C++ standalone executable (`ParkExpansionsWorker.exe`, ~408 KB).
  - Removed bundled Python runtime, libraries, and PyInstaller dependencies.
  - Reduced release archive size from 23.3 MB to 2.6 MB and eliminated heuristic antivirus false positives.

### Fixed
- **Scenery Transfer on 4K Maps:**
  - Resolved `Invalid scenery source hash` validation error that prevented scenery and backdrop vegetation from importing into expanded sandbox parks.
