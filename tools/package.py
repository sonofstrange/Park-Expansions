from pathlib import Path
import hashlib,json,zipfile,shutil
root=Path(__file__).resolve().parents[1]
source=root/'work/boundarylab/Mod_BoundaryLab'
dist=root/'dist';dist.mkdir(exist_ok=True)
output=dist/'Park-Expansions-0.51.zip'
release_dir=dist/'release/Mod_BoundaryLab'

# Clean previous release directory if exists
if release_dir.parent.is_dir():
    shutil.rmtree(release_dir.parent, ignore_errors=True)
release_dir.mkdir(parents=True, exist_ok=True)

files={}
for name in ('Main.ovl','Manifest.xml','Config.ini'):
    files[name]=(source/name).read_bytes()
for name in ('ParkExpansionsBridge.dll',):
    files['Compatibility/'+name]=(source/'Compatibility'/name).read_bytes()

# Native C++ standalone worker
worker=root/'build/ParkExpansionsWorker.exe'
if not worker.is_file():
    worker=source/'Compatibility/AutoWorker/ParkExpansionsWorker.exe'
if not worker.is_file(): raise SystemExit('Build the native worker first: tools/build_worker.cmd')
files['Compatibility/AutoWorker/ParkExpansionsWorker.exe']=worker.read_bytes()

# Pre-packaged stock scenery decor scripts
maps_dir=source/'Maps'
if maps_dir.is_dir():
    for path in sorted(maps_dir.glob('*.decor.*')):
        files['Maps/'+path.name]=path.read_bytes()

# Pre-packaged 4K scenery decor scripts if available
maps4096_dir=source/'Maps4096'
if maps4096_dir.is_dir():
    for path in sorted(maps4096_dir.glob('*.decor.*')):
        files['Maps4096/'+path.name]=path.read_bytes()

# 1. Write release folder directly
for rel_path, data in sorted(files.items()):
    target_file = release_dir / rel_path
    target_file.parent.mkdir(parents=True, exist_ok=True)
    target_file.write_bytes(data)

# 2. Write release ZIP
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for name,data in sorted(files.items()):
        z.writestr('Mod_BoundaryLab/'+name,data)

with zipfile.ZipFile(output) as z:
    assert z.testzip() is None
    assert not any(n.endswith('.bin') or n.endswith('.trn') or '/AutoConversion/' in n or n.endswith('.park2') for n in z.namelist())

manifest={'version':'0.51','archive':output.name,'archive_sha256':hashlib.sha256(output.read_bytes()).hexdigest(),
 'bytes':output.stat().st_size,'file_sha256':{'Mod_BoundaryLab/'+n:hashlib.sha256(d).hexdigest() for n,d in sorted(files.items())}}
(root/'release-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')

print(f"Archive: {output} ({round(output.stat().st_size/1024/1024, 2)} MiB)")
print(f"Release folder: {release_dir} ({len(files)} files)")
