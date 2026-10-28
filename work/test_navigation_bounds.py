"""Run the stock and patched NavigationWorld initializer in private test memory.
No live game process is attached to or started; the original EXE is read-only.
"""
import ctypes, struct
from pathlib import Path
import pefile, capstone
pe=pefile.PE(r'D:\SteamLibrary\steamapps\common\Planet Coaster 2\PlanetCoaster2.exe',fast_load=True)
assert pe.FILE_HEADER.TimeDateStamp==0x6abfabee
md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_64);md.detail=True
begin,end=0x164c500,0x164c7f5
stock=pe.get_data(begin,end-begin)
instructions=list(md.disasm(stock,begin))
assert not any(i.mnemonic=='call' for i in instructions), 'Only test the self-contained initializer'
k=ctypes.WinDLL('kernel32',use_last_error=True)
k.VirtualAlloc.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_uint32];k.VirtualAlloc.restype=ctypes.c_void_p
k.VirtualProtect.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.POINTER(ctypes.c_uint32)]
k.VirtualFree.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32]
size=0x3200000
image=k.VirtualAlloc(None,size,0x3000,4);assert image
ctypes.memmove(image+begin,stock,len(stock))
for ins in instructions:
 for operand in ins.operands:
  if operand.type==capstone.x86.X86_OP_MEM and operand.mem.base==capstone.x86.X86_REG_RIP:
   rva=ins.address+ins.size+operand.mem.disp
   assert 0<=rva<size-16
   ctypes.memmove(image+rva,pe.get_data(rva,16),16)
old=ctypes.c_uint32()
assert k.VirtualProtect(image+0x164c000,4096,0x20,ctypes.byref(old))
initialize=ctypes.WINFUNCTYPE(None,ctypes.c_void_p)(image+begin)
manager=ctypes.create_string_buffer(0x1000)
def values():
 data=manager.raw
 return (struct.unpack_from('<6f',data,0x5f0),struct.unpack_from('<2I',data,0xa38),struct.unpack_from('<2I',data,0xa4c),struct.unpack_from('<2I',data,0xa70))
initialize(manager)
bounds,tiles,cells,budget=values()
assert bounds==(-512,)*3+(512,)*3 and tiles==(128,128) and cells==(4096,4096)
print('PASS actual stock initializer: bounds +/-512, tiles 128 x 128, cell grid 4096 x 4096, Detour budget',budget)
dll=ctypes.CDLL(str(Path('build/bridge_contract.dll').resolve()))
backward=dll.TestNavigationBackwardAllocation;backward.argtypes=[];backward.restype=ctypes.c_int
assert backward()==1, 'An unavailable forward window must fall back to an allocation below the anchor'
print('PASS forward address window unavailable: backward RIP allocation succeeds')
configure=dll.TestNavigationBounds;configure.argtypes=[ctypes.c_void_p,ctypes.c_size_t];configure.restype=ctypes.c_int
assert configure(image,100)==0
# Fingerprint mismatch must fail without modifying either instruction.
assert k.VirtualProtect(image+0x164c000,4096,0x40,ctypes.byref(old))
ctypes.c_ubyte.from_address(image+begin+2).value^=1
before=ctypes.string_at(image+begin,len(stock))
assert configure(image,size)==0 and ctypes.string_at(image+begin,len(stock))==before
ctypes.memmove(image+begin,stock,len(stock))
assert configure(image,size)==1
patched=ctypes.string_at(image+begin,len(stock))
assert configure(image,size)==1 and ctypes.string_at(image+begin,len(stock))==patched
for _ in range(3):
 ctypes.memset(manager,0,len(manager));initialize(manager)
 bounds,tiles,cells,actual_budget=values()
 assert bounds==(-2048,)*3+(2048,)*3 and tiles==(512,512) and cells==(16384,16384)
 assert actual_budget==budget, 'Existing Detour active-tile/polygon budget must not be enlarged'
print('PASS actual patched initializer: bounds +/-2048, tiles 512 x 512, unchanged Detour budget; repeated world creation')
# Only displacements of the two bounds loads may change; shared game constants stay intact.
changed={i for i,(a,b) in enumerate(zip(stock,patched)) if a!=b}
allowed={r-begin+n for r in (0x164c50c,0x164c518) for n in range(3,7)}
assert changed and changed<=allowed
for rva in (0x30de520,0x30ddfc0):
 assert ctypes.string_at(image+rva,16)==pe.get_data(rva,16)
print('PASS exact code guard, no partial writes, idempotence, only two RIP operands changed, original constants retained')
k.VirtualFree(image,0,0x8000)
