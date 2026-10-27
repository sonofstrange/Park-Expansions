# Building Park Expansions 0.52

Run commands from the repository root on **64-bit Windows**. Source for every mod-specific compiled component is included. No game executable or save is needed to compile the DLL or worker.

## Native bridge DLL

Install Visual Studio Build Tools with the **Desktop development with C++** workload and a Windows SDK. Open an **x64 Native Tools Command Prompt**:

```bat
tools\build_native.cmd
```

This compiles `work/compatibility/bridge.cpp` using MSVC `/std:c++17 /EHsc /O2 /MT /LD`, builds and runs the argument-reader tests, then copies the DLL into the staged mod.

## Native terrain generator & conversion worker EXE

The worker is written in high-performance C++ (`work/compatibility/worker_main.cpp`) with single-file `miniz` compression. Open an **x64 Native Tools Command Prompt**:

```bat
tools\build_worker.cmd
```

This compiles `ParkExpansionsWorker.exe` (approx. 408 KB) using MSVC `/std:c++17 /O2 /MT /EHsc`, with zero runtime dependencies. It replaces the previous PyInstaller bundle, drastically reducing size from 22.3 MB down to ~1.0 MB packaged, while completing 4K voxel generation in 30–60 seconds.

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

Creates `dist/Park-Expansions-0.52.zip` and updates `release-manifest.json`.
