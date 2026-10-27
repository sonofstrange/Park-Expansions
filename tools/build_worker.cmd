@echo off
setlocal
cd /d "%~dp0.."
if not exist build mkdir build
cl /std:c++17 /O2 /MT /EHsc /utf-8 /Fe:build\ParkExpansionsWorker.exe work\compatibility\worker_main.cpp work\compatibility\miniz.c /link /MACHINE:X64
if errorlevel 1 exit /b 1
if not exist work\boundarylab\Mod_BoundaryLab\Compatibility\AutoWorker mkdir work\boundarylab\Mod_BoundaryLab\Compatibility\AutoWorker
copy /y build\ParkExpansionsWorker.exe work\boundarylab\Mod_BoundaryLab\Compatibility\AutoWorker\ParkExpansionsWorker.exe
exit /b 0
