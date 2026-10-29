"""Native donor selection is derived from original boundary data, not metadata."""
import ctypes,struct,sys
from pathlib import Path
sys.path.insert(0,str(Path('work/compatibility').resolve()))
from terrain_codec import unpack,clients,put_uint
from convert_park import scalar
bridge=ctypes.CDLL(str(Path('build/bridge_contract.dll').resolve()))
choose=bridge.TestBoundaryBiome
choose.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.POINTER(ctypes.c_double),ctypes.c_uint32]
choose.restype=ctypes.c_int
root=Path(r'D:/SteamLibrary/steamapps/common/Planet Coaster 2/Parks/Sandbox')
stock=[]
for index,name in enumerate(['Temperate','Tropical','Taiga','Mediterranean']):
 _,raw=unpack(root/(name+'Sandbox.bin'))
 _,start,_,end=next(b for b in clients(raw)[3]if b[0]=='Boundary')
 block=raw[start:end];stock.append(block);output=(ctypes.c_double*7)()
 assert choose(block,len(block),output,0)==index,name
 assert all(abs(n)<512 for n in output[3:])
 print('PASS native original contour identifies',name,'and returns actual seed/bounds')
# Reported failure: metadata may say tropical, but the donor must be Mediterranean.
med=stock[3];out=(ctypes.c_double*7)()
assert choose(med,len(med),out,0)==3
# Retain a saved post's modified elevation instead of a hardcoded donor seed.
pos=0
for _ in range(5):_,pos=scalar(med,pos)
y_start=pos;old_y,y_end=scalar(med,pos)
new_y=old_y+15
packed=struct.pack('>f',new_y)
high=packed[0]
tag=0x80|((high&0x7f)-0x30)|((high&0x80)>>2)
changed=med[:y_start]+bytes([tag])+packed[1:]+med[y_end:]
assert choose(changed,len(changed),out,0)==3 and abs(out[1]-new_y)<0.0001
assert choose(med,len(med),out,0)==3
assert abs(out[3]-(-510.1216431))<0.001 and abs(out[4]-488.7711792)<0.001
assert choose(med[:20],20,out,0)==-1
bad=bytes([99])+med[1:];assert choose(bad,len(bad),out,0)==-1
assert choose(bytes([4,0,3]),3,out,0)==-1
# Unknown/custom/expanded rings must not fall back to whichever biome metadata says.
rows=bytes([4,0,4])
for i,(x,z)in enumerate([(-600,-600),(600,-600),(600,600),(-600,600)]):
 for v in [i+1,x,0,z,1,0,0,0,40,0]:
  if v>=0:rows+=put_uint(v)
  else:
   q=bytearray(put_uint(-v));q[0]|=8;rows+=q
assert choose(rows,len(rows),out,40)==-1
print('PASS Mediterranean regression, malformed input and unknown contours fail closed')

lookup=bridge.TestParkBoundaryType
lookup.argtypes=[ctypes.c_void_p,ctypes.c_size_t];lookup.restype=ctypes.c_int
for index in [0,40,41,200]:
 strings=b'Strings>'+put_uint(index+1)+b'\xf3Other\x00'*index+b'\xf3ParkBoundary\x00'
 assert lookup(strings,len(strings))==index
missing=b'Strings>\x01\xf3Missing\x00'
assert lookup(missing,len(missing))==-1
print('PASS save-local ParkBoundary string IDs are resolved, never hardcoded')
