# Building Park Expansions 0.56

Run commands from the repository root on **64-bit Windows**. Source for every mod-specific compiled component is included. No game executable or save is needed to compile the DLL.

## Native bridge DLL (with embedded generator)

Install Visual Studio Build Tools with the **Desktop development with C++** workload and a Windows SDK. Open an **x64 Native Tools Command Prompt**:

```bat
tools\build_native.cmd
```

This compiles `work/compatibility/bridge.cpp` and `work/compatibility/miniz.c` using MSVC `/std:c++17 /EHsc /O2 /MT /LD`, builds and runs the native contract tests, then copies the DLL (`ParkExpansionsBridge.dll`, ~415 KB) into `work/boundarylab/Mod_BoundaryLab/Compatibility/`.

All voxel terrain octree generation, mipmap downsampling, and dynamic scenery backdrop extraction are fully self-contained inside the DLL running on background threads. No separate `.exe` process or external runtime is required.

## Lua and UI package (Main.ovl)

The Lua sources are in `work/boundarylab/Main/`; authored JavaScript and CSS are in `work/boundarylab/UI/`. Obtain [Cobra Tools](https://github.com/OpenNaja/cobra-tools) (revision `2dd9d1445608d6171c1ec1f2333cefb4d81a1317`) and its Python dependencies. Set the `COBRA_TOOLS` environment variable to that checkout before running the OVL builder. Include the checkout's Lua utilities and hash data. Python is a build dependency only and is not included in the mod.

```bat
python tools/build_ui.py
python work/build_boundarylab.py
```

The OVL builder syntax-checks Lua, creates a Planet Coaster 2 ZLIB OVL, and checks the Lua files and embedded UI resources against their sources.

## Packaging

```bat
python tools/package.py
```

Creates `dist/Park-Expansions-0.56.zip` (about 257 KiB) containing only 4 clean files and updates `release-manifest.json`.


## Navigation regression checks

The build creates a test-only `build/bridge_contract.dll`; it is excluded from the archive. With `pefile` and `capstone` installed and the supported game EXE available locally, run `python work/test_navigation_bounds.py` and `python work/test_crowd_grid.py`. These tests use private memory buffers; they do not attach to or launch the game. The Crowd test stubs unused bucket storage allocation and runs the native coordinate lookup. Source for the version-gated memory changes is in `sea_raster.h`, `navigation_bounds.h` and `crowd_grid.h`.
