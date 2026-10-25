# Building Park Expansions 0.35

Run commands from the repository root on **64-bit Windows**. Source for every mod-specific compiled component is included. Prepared terrain files are checked in; the following builds reuse these files and do not regenerate the landscape. No game executable or save is needed to compile the DLL or worker.

## Native bridge DLL

Install Visual Studio Build Tools with the **Desktop development with C++** workload and a Windows SDK. Open an **x64 Native Tools Command Prompt**:

```bat
tools\build_native.cmd
```

This compiles `work/compatibility/bridge.cpp` using MSVC `/std:c++17 /EHsc /O2 /MT /LD`, builds and runs the argument-reader tests, then copies the DLL into the staged mod. The published DLL was built with Visual Studio 18 Community. The bridge test is a build artifact, not part of the mod.

## Conversion worker EXE

The worker consists of `auto_convert.py`, `convert_park.py` and `terrain_codec.py` in `work/compatibility/`. They use the Python standard library. The published worker used **64-bit CPython 3.14.6** and **PyInstaller 6.22.2**, in console/onedir mode. No UPX installation was used.

```bat
python -m pip install PyInstaller==6.22.2
tools\build_worker.cmd
```

The output includes `ParkExpansionsWorker.exe`, the Python runtime and `_internal/base_library.zip`. The bridge starts the console executable with `CREATE_NO_WINDOW`. The ZIP is part of Python's runtime, not another mod download. Preserve the bundled Python and PyInstaller license notices when packaging.

## Lua and UI package (Main.ovl)

The Lua sources are in `work/boundarylab/Main/`; authored JavaScript and CSS are in `work/boundarylab/UI/`. The UI imports existing game components at runtime; they are not copied into this repository.

Obtain [Cobra Tools](https://github.com/OpenNaja/cobra-tools), revision `2dd9d1445608d6171c1ec1f2333cefb4d81a1317`. Follow its Python dependency requirements (Python 3.11). Use a separate environment from the worker's Python 3.14 environment:

```bat
git clone https://github.com/OpenNaja/cobra-tools.git work\cobra-tools
git -C work\cobra-tools checkout 2dd9d1445608d6171c1ec1f2333cefb4d81a1317
py -3.11 -m venv build\ovl-env
build\ovl-env\Scripts\python -m pip install ./work/cobra-tools
build\ovl-env\Scripts\python tools/build_ui.py
build\ovl-env\Scripts\python work/build_boundarylab.py
```

The OVL builder syntax-checks Lua, creates a Planet Coaster 2 ZLIB OVL, reloads it, and checks the two Lua files and two embedded UI resources against their sources. Cobra Tools must include its Lua utilities and hash data.

## Tests

The bridge script runs its native tests. These Lua tests use simulated APIs and do not establish in-game compatibility:

```bat
work\cobra-tools\modules\formats\utils\luadec\lua.exe work/test_boundarylab_research.lua
work\cobra-tools\modules\formats\utils\luadec\lua.exe work/test_boundarylab.lua
work\cobra-tools\modules\formats\utils\luadec\lua.exe work/test_boundarylab_terrain.lua
work\cobra-tools\modules\formats\utils\luadec\lua.exe work/test_auto_conversion_032.lua
```

The historical numeric suffix in a test filename is not the mod version. Placement, rendering, saving and reloading still require manual testing in the game.

## Package

```bat
python tools/package.py
```

Produces `dist/Park-Expansions-0.35.zip` with one `Mod_BoundaryLab` folder and no instructions inside. The repository also includes the original release binaries, prepared maps and third-party runtime. Rebuilding with a different toolchain may produce different binary hashes; byte-for-byte reproducibility is not claimed. See `release-manifest.json` for the original release hashes.
