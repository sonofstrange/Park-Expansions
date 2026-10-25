from pathlib import Path
import hashlib,json,zipfile
root=Path(__file__).resolve().parents[1]
source=root/'work/boundarylab/Mod_BoundaryLab'
output=root/'dist/Park-Expansions-0.38-test.zip';output.parent.mkdir(exist_ok=True)
files={}
for name in ('Main.ovl','Manifest.xml','Config.ini'):
 files[name]=(source/name).read_bytes()
for name in ('ParkExpansionsBridge.dll','Python-LICENSE.txt','PyInstaller-COPYING.txt'):
 files['Compatibility/'+name]=(source/'Compatibility'/name).read_bytes()
# Use exactly the freshly frozen runtime, without leftovers from an older build.
runtime=root/'build/runtime/ParkExpansionsWorker'
if not runtime.is_dir(): raise SystemExit('Build the conversion worker first: tools/build_worker.cmd')
for path in sorted(runtime.rglob('*')):
 if path.is_file():files['Compatibility/AutoWorker/'+path.relative_to(runtime).as_posix()]=path.read_bytes()
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
 for name,data in sorted(files.items()):z.writestr('Mod_BoundaryLab/'+name,data)
with zipfile.ZipFile(output) as z:
 assert z.testzip() is None
 assert not any('/Maps/' in n or '/AutoConversion/' in n or n.endswith('.park2') for n in z.namelist())
 assert any('numpy' in n and 'LICENSE' in n for n in z.namelist())
manifest={'version':'0.38-test','archive':output.name,'archive_sha256':hashlib.sha256(output.read_bytes()).hexdigest(),
 'bytes':output.stat().st_size,'file_sha256':{'Mod_BoundaryLab/'+n:hashlib.sha256(d).hexdigest() for n,d in sorted(files.items())}}
(root/'release-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
print(output)
print(round(output.stat().st_size/1024/1024,2),'MiB;',len(files),'files; no prepared maps, saves or cache')
