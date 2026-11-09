"""Boundary detour ABI/override check in private executable memory only."""
import ctypes as c
from pathlib import Path
import pefile
from native_test_build import identify,select
pe=pefile.PE(r'D:/SteamLibrary/steamapps/common/Planet Coaster 2/PlanetCoaster2.exe',fast_load=True)
updated=identify(pe);site=0xe492e0 if pe.FILE_HEADER.TimeDateStamp==0x6ae8f335 else 0xe48550 if updated else 0xdf4430
k=c.WinDLL('kernel32',use_last_error=True)
k.VirtualAlloc.argtypes=[c.c_void_p,c.c_size_t,c.c_uint32,c.c_uint32];k.VirtualAlloc.restype=c.c_void_p
k.VirtualFree.argtypes=[c.c_void_p,c.c_size_t,c.c_uint32]
size=(site+4095+64)&~4095;image=k.VirtualAlloc(None,size,0x3000,0x40);assert image
stock=pe.get_data(site,16)
# The real displaced prolog followed by a false-returning body with a matching
# epilog tests the trampoline's stack/argument contract without engine objects.
epilog=bytes.fromhex('33c04881c4980000005f5bc3')
c.memmove(image+site,stock+epilog,len(stock+epilog))
dll=c.CDLL(str(Path('build/bridge_contract.dll').resolve()));select(dll,pe)
apply=dll.TestBoundaryHook;apply.argtypes=[c.c_void_p,c.c_size_t];apply.restype=c.c_int
assert apply(image,100)==0
c.c_ubyte.from_address(image+site).value^=1
assert apply(image,size)==0
c.memmove(image+site,stock,16)
assert apply(image,size)==1 and apply(image,size)==1
set_size=dll.TestBoundarySize;set_size.argtypes=[c.c_float];set_size.restype=c.c_int
query=c.WINFUNCTYPE(c.c_ubyte,c.c_void_p,c.c_void_p,c.c_ubyte)(image+site)
assert not query(None,(c.c_float*4)(600,0,0,0),False),'Inactive hook must delegate to the original function'
assert set_size(4088)
for x,y,z,inside in [(0,0,0,True),(600,20,570,True),(-2000,50,2000,True),(3000,0,0,False),(0,2500,0,False)]:
 point=(c.c_float*4)(x,y,z,0)
 assert bool(query(None,point,False))==inside,(x,y,z)
assert set_size(2040)
assert not query(None,(c.c_float*4)(1500,0,0,0),False)
assert set_size(4088)
assert query(None,(c.c_float*4)(1500,0,0,0),False)
for bad in [float('nan'),float('inf'),-1,50]:assert not set_size(bad)
assert set_size(0)
assert not query(None,(c.c_float*4)(0,0,0,0),False)
c.memmove(image+site+16,bytes.fromhex('b001'),2)
assert query(None,(c.c_float*4)(3000,0,0,0),False),'Original true results must remain true when disabled'
print('PASS activation, 2K/4K switching, reset, invalid sizes and original passthrough')
print('PASS boundary detour: signature rejection, trampoline ABI, enlarged bounds and repeated initialization')
assert k.VirtualFree(image,0,0x8000)
