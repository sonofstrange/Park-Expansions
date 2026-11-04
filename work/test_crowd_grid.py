"""Exercise the stock Crowd grid initializer and checked coordinate lookup.

Runs copied, self-contained native math in private memory, never the game.
The unused cell-storage allocation call is replaced by a test-only size stub;
the real bounds, dimensions and lookup code are retained.
"""
import ctypes,struct
from pathlib import Path
import pefile,capstone

pe=pefile.PE(r'D:\SteamLibrary\steamapps\common\Planet Coaster 2\PlanetCoaster2.exe',fast_load=True)
from native_test_build import identify,select,rva as game_rva
updated=identify(pe)
md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_64);md.detail=True
k=ctypes.WinDLL('kernel32',use_last_error=True)
k.VirtualAlloc.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_uint32];k.VirtualAlloc.restype=ctypes.c_void_p
k.VirtualProtect.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.POINTER(ctypes.c_uint32)]
k.VirtualFree.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32]
size=0x3200000;image=k.VirtualAlloc(None,size,0x3000,4);assert image
constructor=(game_rva(0x96c870),game_rva(0x96d5fd))
for begin,end in [(game_rva(0x968760),game_rva(0x96893e)),(game_rva(0x968ae0),game_rva(0x968cb0)),(game_rva(0x971350),game_rva(0x97150a)),constructor]:
    code=pe.get_data(begin,end-begin);ctypes.memmove(image+begin,code,len(code))
    if (begin,end)==constructor:continue
    for ins in md.disasm(code,begin):
        if ins.mnemonic=='call':assert ins.operands[0].imm in (game_rva(0x9bf8a0),game_rva(0x9bfa10))
        for op in ins.operands:
            if op.type==capstone.x86.X86_OP_MEM and op.mem.base==capstone.x86.X86_REG_RIP:
                rva=ins.address+ins.size+op.mem.disp
                assert 0<=rva<size-16
                ctypes.memmove(image+rva,pe.get_data(rva,16),16)
ctypes.memmove(image+game_rva(0x2f98338),pe.get_data(game_rva(0x2f98338),16),16)
# Record the requested storage count, skip storage that the lookup never reads.
ctypes.memmove(image+game_rva(0x9bfa10),b'\x4c\x89\x01\xc3',4)
old=ctypes.c_uint32()
pages={address for a,b in [(game_rva(0x968760),game_rva(0x96893e)),(game_rva(0x968ae0),game_rva(0x968cb0)),(game_rva(0x971350),game_rva(0x97150a)),(game_rva(0x9bfa10),game_rva(0x9bfa10)+4)] for address in range(a&~4095,b,4096)}
for page in pages:assert k.VirtualProtect(image+page,4096,0x20,ctypes.byref(old))
# Register the copied functions' original unwind metadata for test-only SEH.
directory=pe.OPTIONAL_HEADER.DATA_DIRECTORY[3]
entries=[entry for entry in struct.iter_unpack('<III',pe.get_data(directory.VirtualAddress,directory.Size))
    if entry[0] in (game_rva(0x968760),game_rva(0x971350)) or game_rva(0x968ae0)<=entry[0]<game_rva(0x968cb0)]
for begin,end,unwind in entries:ctypes.memmove(image+unwind,pe.get_data(unwind,128),128)
runtime=(ctypes.c_uint32*(len(entries)*3))(*(v for entry in entries for v in entry))
k.RtlAddFunctionTable.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint64];k.RtlAddFunctionTable.restype=ctypes.c_ubyte
assert k.RtlAddFunctionTable(runtime,len(entries),image)
dll=ctypes.CDLL(str(Path('build/bridge_contract.dll').resolve()))
select(dll,pe)
safe_initialize=dll.TestCrowdInitialize;safe_initialize.argtypes=[ctypes.c_void_p]*5;safe_initialize.restype=ctypes.c_int
fault=dll.TestNativeFaultAddress;fault.restype=ctypes.c_size_t
lookup=ctypes.WINFUNCTYPE(ctypes.c_void_p,*([ctypes.c_void_p]*4))(image+game_rva(0x968ae0))
owner=ctypes.create_string_buffer(0x2100)
grid=(ctypes.c_char*0x100).from_buffer(owner,0xe90)
def vector(*values):
    owner=ctypes.create_string_buffer(32)
    offset=(-ctypes.addressof(owner))%16
    array=(ctypes.c_float*4).from_buffer(owner,offset)
    array[:]=values;array.owner=owner
    return array
origin=vector(0,0,0,0);scale=vector(1,0,0,0)
def width_from_constructor():
    displacement=struct.unpack('<i',ctypes.string_at(image+game_rva(0x96ce28)+4,4))[0]
    return ctypes.c_float.from_address(image+game_rva(0x96ce28)+8+displacement).value
def create_grid():
    width=width_from_constructor()
    extent=vector(width,0,0,0)
    ctypes.memset(grid,0,len(grid))
    assert safe_initialize(image+game_rva(0x968760),grid,origin,extent,scale),f'Initializer fault RVA {fault()-image:x}'
    return width,struct.unpack_from('<2I',grid.raw,0x60)
def inside(x,z):
    result=(ctypes.c_uint32*2)();position=(ctypes.c_float*4)(x,z,0,0)
    lookup(grid,result,position,None)
    return result[1]!=0xffffffff
# Decode the actual engine's local-cell/zone address back into a world point.
decode=ctypes.WINFUNCTYPE(ctypes.c_void_p,*([ctypes.c_void_p]*3))(image+game_rva(0x971350))
zone=ctypes.create_string_buffer(0x200)
heights=(ctypes.c_float*128)()
ctypes.c_void_p.from_buffer(zone,0xf8).value=ctypes.addressof(heights)
ctypes.c_float.from_buffer(zone,0x190).value=0

def roundtrip(x,z):
    address=ctypes.create_string_buffer(0x40)
    position=vector(x,z,0,0)
    lookup(grid,address,position,None)
    cell,zone_id=struct.unpack_from('<II',address.raw)
    assert zone_id!=0xffffffff
    ctypes.c_void_p.from_buffer(address,0x30).value=ctypes.addressof(zone)
    ctypes.c_uint32.from_buffer(owner,0x180c).value=6
    out=vector(0,0,0,0)
    decode(owner,out,address)
    # A 1-metre cell decodes to its centre, rather than the exact input point.
    assert abs(out[0]-x)<=1 and abs(out[2]-z)<=1,(x,z,list(out),cell,zone_id)
    again=ctypes.create_string_buffer(8)
    lookup(grid,again,vector(out[0],out[2],0,0),None)
    assert again.raw==address.raw[:8],(x,z,list(out),'cell address changed')

assert create_grid()==(1024,(256,256))
assert inside(0,0) and inside(500,0)
for p in [(600,0),(-600,0),(0,600),(0,-600),(1500,1500)]:assert not inside(*p)
for p in [(0,0),(500,500),(-500,-500)]:roundtrip(*p)
print('PASS stock world/cell/world roundtrip and bounds')
configure=dll.TestCrowdGrid;configure.argtypes=[ctypes.c_void_p,ctypes.c_size_t];configure.restype=ctypes.c_int
assert configure(image,100)==0
before=ctypes.string_at(image+constructor[0],constructor[1]-constructor[0])
ctypes.c_ubyte.from_address(image+constructor[0]+1).value^=1
bad=ctypes.string_at(image+constructor[0],len(before))
assert configure(image,size)==0 and ctypes.string_at(image+constructor[0],len(before))==bad
ctypes.memmove(image+constructor[0],before,len(before))
assert configure(image,size)==1 and configure(image,size)==1
assert create_grid()==(4096,(1024,1024))
for p in [(600,0),(-600,0),(0,600),(0,-600),(1500,1500),(2000,-2000),(-2048,-2048)]:assert inside(*p),p
for p in [(2048,0),(0,2048),(-2049,0),(0,-2049)]:assert not inside(*p),p
after=ctypes.string_at(image+constructor[0],len(before))
changed={i for i,(a,b) in enumerate(zip(before,after)) if a!=b}
assert changed and changed<={game_rva(0x96ce28)-constructor[0]+i for i in range(4,8)}
assert ctypes.string_at(image+game_rva(0x2f98338),16)==pe.get_data(game_rva(0x2f98338),16)
for x in [-2047.2,-1500.25,-600.1,-0.2,0.1,600.3,1500.6,2046.9]:
    for z in [-2047.2,-700.5,-0.2,700.5,2046.9]:roundtrip(x,z)
print('PASS enlarged world/cell/world roundtrip across both axes without index aliasing')
print('PASS actual enlarged Crowd lookup accepts exterior points up to +/-2048, rejects outside; only one load changed')
print('PASS cell metadata: 2 MiB -> 32 MiB at the stock scale; storage allocation itself is stubbed in this test')
k.RtlDeleteFunctionTable.argtypes=[ctypes.c_void_p]
assert k.RtlDeleteFunctionTable(runtime)
k.VirtualFree(image,0,0x8000)
