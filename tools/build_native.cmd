@echo off
setlocal
cd /d "%~dp0.."
where cl >nul 2>nul
if errorlevel 1 (
  echo Run this script from an x64 Native Tools Command Prompt for Visual Studio.
  exit /b 1
)
if not exist build mkdir build
cl /nologo /std:c++17 /EHsc /O2 /MT /LD work\compatibility\bridge.cpp /Febuild\ParkExpansionsBridge.dll /Fobuild\bridge.obj /link /DYNAMICBASE /NXCOMPAT
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /O2 /MT /DBRIDGE_TEST work\compatibility\bridge.cpp /Febuild\bridge_test.exe /Fobuild\bridge_test.obj /link /DYNAMICBASE /NXCOMPAT
if errorlevel 1 exit /b 1
build\bridge_test.exe
if errorlevel 1 exit /b 1
copy /y build\ParkExpansionsBridge.dll work\boundarylab\Mod_BoundaryLab\Compatibility\ParkExpansionsBridge.dll >nul
