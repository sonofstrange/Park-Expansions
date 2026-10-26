"""Read-only source integration checks for isolated 4K map generation/cache."""
import argparse,json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent/'compatibility'))
from generate_maps import ensure_maps,source_blob,request_profile
from terrain_codec import Volume,unpack,decode_density,material_parts,clients,digest
p=argparse.ArgumentParser();p.add_argument('--game-dir',required=True,type=Path);args=p.parse_args()
root=Path(__file__).resolve().parents[1]/'build/4k-generation/Mod_BoundaryLab';root.mkdir(parents=True,exist_ok=True)
result=ensure_maps(root,'taiga:4096',lambda n,m:print(n,m,flush=True),game_dir=args.game_dir)
assert result['terrainSize']==4096
name='TaigaSandbox'
_,original=unpack(args.game_dir/'Parks/Sandbox'/(name+'.bin'))
_,expanded=unpack(root/'Maps4096'/(name+'.bin'))
_,underlay=unpack(root/'Maps4096'/(name+'.trn'))
a=Volume(source_blob(original,'VoxelTerrain'))
# Expanded terrain's header differs from the 1024 source marker.
record=next(v for v in clients(expanded)[3]if v[0]=='VoxelTerrain')
marker=b'\x05\x08\x09\x08\xc2\x00\x01\x00'
position=expanded.index(marker,record[2],record[3]);b=Volume(expanded[position:record[3]])
assert b.shape==[8,9,8]
ur=next(v for v in clients(underlay)[3]if v[0]=='VoxelTerrainUnderlay')
up=underlay.index(marker,ur[2],ur[3]);assert underlay[up:ur[3]]==b.data
ad,bd=decode_density(a.deltas),decode_density(b.deltas);am,bm=material_parts(a),material_parts(b)
for index in range(4):
 x=index%2+3;z=index//2+3;target=(z*9+4)*8+x
 at,ab,ae,asign=a.roots[index];bt,bb,be,bsign=b.roots[target]
 assert (at,asign,ad[ab:ae],am[index])==(bt,bsign,bd[bb:be],bm[target])
 assert (x*512-2048,4*512-2304,z*512-2048)==(index%2*512-512,-256,index//2*512-512)
for old,new in zip(clients(original)[3],clients(expanded)[3]):
 assert old[0]==new[0]
 if old[0]!='VoxelTerrain':assert original[old[1]:old[3]]==expanded[new[1]:new[3]]
manifest=json.loads((root/'Maps4096'/(name+'.generation.json')).read_text(encoding='utf-8'))
assert manifest['size']==4096
for file,sha in manifest['outputs'].items():assert digest((root/'Maps4096'/file).read_bytes())==sha
assert result['scenery']['count']>4649
assert request_profile('taiga')==('taiga',2048,'Maps')
for value in ['taiga:1024','taiga:8192','taiga:4096:4096','../taiga:4096']:
 try:request_profile(value)
 except ValueError:pass
 else:raise AssertionError(value)
assert ensure_maps(root,'taiga:4096',lambda *_:None,game_dir=args.game_dir)['cached']
print('PASS 4K volume/underlay, original geometry/materials/world positions, untouched nonterrain clients, scenery extent and cache isolation')
