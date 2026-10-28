@echo off
setlocal
cd /d "%~dp0.."
where cl >nul 2>nul
if errorlevel 1 (
  if exist "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" (
    call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
  ) else if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" (
    call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
  )
)
if not exist build mkdir build
cl /nologo /std:c++17 /EHsc /O2 /MT /I work\compatibility /LD work\compatibility\bridge.cpp work\compatibility\miniz.c /Febuild\ParkExpansionsBridge.dll /Fobuild\ /link /DYNAMICBASE /NXCOMPAT advapi32.lib shell32.lib ole32.lib
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /O2 /MT /I work\compatibility /DBRIDGE_TEST work\compatibility\bridge.cpp work\compatibility\miniz.c /Febuild\bridge_test.exe /Fobuild\ /link /DYNAMICBASE /NXCOMPAT advapi32.lib shell32.lib ole32.lib
if errorlevel 1 exit /b 1
build\bridge_test.exe
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /O2 /MT /I work\compatibility /LD /DBRIDGE_TEST work\compatibility\bridge.cpp work\compatibility\miniz.c /Febuild\bridge_contract.dll /Fobuild\ /link /DYNAMICBASE /NXCOMPAT advapi32.lib shell32.lib ole32.lib
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /O2 /MT /I work\compatibility /DCONVERT_CLI work\compatibility\bridge.cpp work\compatibility\miniz.c /Febuild\convert_cli.exe /Fobuild\ /link /DYNAMICBASE /NXCOMPAT advapi32.lib shell32.lib ole32.lib
if errorlevel 1 exit /b 1
copy /y build\ParkExpansionsBridge.dll work\boundarylab\Mod_BoundaryLab\Compatibility\ParkExpansionsBridge.dll >nul
echo Build succeeded!
