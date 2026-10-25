@echo off
setlocal
cd /d "%~dp0.."
python -m PyInstaller --noconfirm --clean --onedir --console --noupx --name ParkExpansionsWorker --distpath build\runtime --workpath build\pyinstaller --specpath build --paths work\compatibility work\compatibility\auto_convert.py
if errorlevel 1 exit /b 1
robocopy build\runtime\ParkExpansionsWorker work\boundarylab\Mod_BoundaryLab\Compatibility\AutoWorker /E /NFL /NDL /NJH /NJS
if errorlevel 8 exit /b 1
exit /b 0
