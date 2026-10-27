# Building Park Expansions 0.52

Run commands from the repository root on **64-bit Windows**. Source for every mod-specific compiled component is included. No game executable or save is needed to compile the DLL.

## Native bridge DLL (with embedded generator)

Install Visual Studio Build Tools with the **Desktop development with C++** workload and a Windows SDK. Open an **x64 Native Tools Command Prompt**:

```bat
tools\build_native.cmd
```

This compiles `work/compatibility/bridge.cpp` and `work/compatibility/miniz.c` using MSVC `/std:c++17 /EHsc /O2 /MT /LD`, builds and runs the native contract tests, then copies the DLL (`ParkExpansionsBridge.dll`, ~415 KB) into `work/boundarylab/Mod_BoundaryLab/Compatibility/`.

All voxel terrain octree generation, mipmap downsampling, and dynamic scenery backdrop extraction are fully self-contained inside the DLL running on background threads. No separate `.exe` process or external runtime is required.

## Lua and UI package (Main.ovl)

The Lua sources are in `work/boundarylab/Main/`; authored JavaScript and CSS are in `work/boundarylab/UI/`.

```bat
python tools/build_ui.py
python work/build_boundarylab.py
```

The OVL builder syntax-checks Lua, creates a Planet Coaster 2 ZLIB OVL, and checks the Lua files and embedded UI resources against their sources.

## Packaging

```bat
python tools/package.py
```

Creates `dist/Park-Expansions-0.52.zip` (~234 KiB) containing only 4 clean files and updates `release-manifest.json`.
