from pathlib import Path
import zipfile
root=Path(__file__).resolve().parents[1]
source=root/'work/boundarylab/Mod_BoundaryLab'
output=root/'dist/Park-Expansions-0.35.zip';output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
 for path in sorted(source.rglob('*')):
  if path.is_file() and 'AutoConversion' not in path.parts:
   z.write(path,'Mod_BoundaryLab/'+path.relative_to(source).as_posix())
with zipfile.ZipFile(output) as z:assert z.testzip() is None
print(output)
