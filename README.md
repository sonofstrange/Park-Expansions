![Park Expansions](assets/header.png)

# Park Expansions

Expand your park through two research branches: park size and building height. Each branch has five upgrades.

- Buildable area up to **2040 × 2040 m**, within a 2048 × 2048 m terrain volume.
- Building ceiling up to **world Y = 2048 m**. Individual ride limits may differ.
- Original landscape retained, with surrounding landscape made editable.
- Automatic conversion of supported existing local Sandbox and Challenge parks.
- Optional manual limits in `Config.ini`, with the research tree disabled.

## Download and installation

Download the mod ZIP from [Releases](../../releases). Close the game, install **ACSE** and **ForgeUtils**, then extract the complete `Mod_BoundaryLab` folder into `Planet Coaster 2/Win64/ovldata/`.

Keep the internal folder name `Mod_BoundaryLab`; it is required by the mod. Open **Research → Park Expansions** in the game.

## Compatibility

Version **0.35**. Prepared terrain supports Temperate, Tropical, Taiga and Mediterranean parks. Automatic conversion is gated to game build **1.11.3.986758F** and supported local save formats; unsupported parks are left unchanged. Career, Franchise and Workshop-only saves are not supported by the converter.

The maximum tested buildable width is 2040 m, leaving a 4 m margin at each terrain edge. Setting 4096 in the config does not generate a larger terrain.

## Configuration

`Mod_BoundaryLab/Config.ini` uses Lua syntax despite its file extension:

```lua
ResearchEnabled = true
ManualParkSize = 2040
ManualMaxHeight = 2048
```

Set `ResearchEnabled = false` to hide the upgrade tree and apply manual limits when loading the park. Reload after editing. Heights are absolute world Y coordinates. Values above 2048 may be unstable and remain subject to engine and loaded-terrain limits.

Each branch costs 12,500 / 25,000 / 50,000 / 100,000 / 200,000 research points. Upgrades are free if research is disabled by the game's Sandbox settings.

## Experimental

Back up your saves before use. Bugs, crashes, visual glitches and save compatibility issues are possible. Some changes may persist after removing the mod. Loading expanded saves without the mod has not been verified.

## Source and review

See [BUILD.md](BUILD.md) for build steps and [REVIEW.md](REVIEW.md) for the executable components and file access. The complete distributable is in `work/boundarylab/Mod_BoundaryLab/`. No player saves or conversion cache are included.

This repository does not grant a new license for Frontier assets or bundled third-party components. Their respective owners' terms apply; bundled Python and PyInstaller notices are retained.
