"""Native 2K/4K conversion preserves source clients and original voxel roots."""
import ctypes,json,re,sys,tempfile,zipfile,shutil,hashlib
from pathlib import Path
sys.path.insert(0,str(Path('work/compatibility').resolve()))
from terrain_codec import unpack,clients,Volume,decode_density,material_parts
root=Path(r'D:/SteamLibrary/steamapps/common/Planet Coaster 2')
mod=root/'Win64/ovldata/Mod_BoundaryLab'
_,original=unpack(root/'Parks/Sandbox/TemperateSandbox.bin')
blocks=clients(original)[3]
vt=next(b for b in blocks if b[0]=='VoxelTerrain')
marker=bytes.fromhex('05020102c2000100');pos=original.index(marker,vt[2],vt[3]);old=Volume(original[pos:vt[3]])
od=decode_density(old.deltas);om=material_parts(old)
dll=ctypes.CDLL(str(Path('build/bridge_contract.dll').resolve()))
convert=dll.TestConvertFromFile;convert.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_char_p,ctypes.c_char_p]
with tempfile.TemporaryDirectory(prefix='pe-convert4k-')as temp:
 stage=Path(temp);source=stage/'Fixture-1234ABCD.park2'
 with zipfile.ZipFile(source,'w')as z:
  z.writestr('metadata',b'{"tSave":{}}');z.writestr('parkdata',bytes.fromhex('ff00fe01')+bytes(12)+original)
 source_hash=hashlib.sha256(source.read_bytes()).digest();outputs=[]
 for size,folder in [(2048,'Maps'),(4096,'Maps4096')]:
  dest=stage/folder;dest.mkdir()
  for ext in ('bin','trn'):shutil.copyfile(mod/folder/('TemperateSandbox.'+ext),dest/('TemperateSandbox.'+ext))
  nonce=f'{size}-1';convert(str(stage),str(source),f'temperate:{size}'.encode(),nonce.encode())
  result=(stage/'AutoConversion'/f'Result-{nonce}.lua').read_text(encoding='utf-8')
  assert 'status="ready"'in result,result
  assert f'terrainSize={size}'in result,result
  filename=re.search(r'AutoConversion/([a-f0-9]+)\.bin',result)[1];outputs.append(filename)
  _,expanded=unpack(stage/'AutoConversion'/(filename+'.bin'))
  eb=clients(expanded)[3]
  assert len(eb)==len(blocks)
  for a,b in zip(blocks,eb):
   assert a[0]==b[0]
   if a[0]!='VoxelTerrain':assert original[a[1]:a[3]]==expanded[b[1]:b[3]],a[0]
  block=next(b for b in eb if b[0]=='VoxelTerrain');width=size//512;inner=width//2-1
  mark=bytes([5,width,9,width])+bytes.fromhex('c2000100');start=expanded.index(mark,block[2],block[3]);v=Volume(expanded[start:block[3]])
  assert v.shape==[width,9,width];d=decode_density(v.deltas);m=material_parts(v)
  for i in range(4):
   x=i%2+inner;z=i//2+inner;j=(z*9+4)*width+x
   at,ab,ae,sign=old.roots[i];bt,bb,be,bsign=v.roots[j]
   assert (at,sign,od[ab:ae],om[i])==(bt,bsign,d[bb:be],m[j])
   assert (x*512-size//2,4*512-2304,z*512-size//2)==(i%2*512-512,-256,i//2*512-512)
  print('PASS native conversion',size,'original clients, voxel trees, materials, densities and coordinates',flush=True)
  convert(str(stage),str(source),f'temperate:{size}'.encode(),f'{size}-2'.encode())
  assert 'status="ready"'in(stage/'AutoConversion'/f'Result-{size}-2.lua').read_text(encoding='utf-8')
 assert outputs[0]!=outputs[1]
 assert hashlib.sha256(source.read_bytes()).digest()==source_hash
 print('PASS isolated size-specific cache, cache reload and original source unchanged')
