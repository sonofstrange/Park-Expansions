"""Exercise the stock Crowd grid initializer and checked coordinate lookup.

Runs copied, self-contained native math in private memory, never the game.
The unused cell-storage allocation call is replaced by a test-only size stub;
the real bounds, dimensions and lookup code are retained.
"""
import ctypes,struct
from pathlib import Path
import pefile,capstone

pe=pefile.PE(r'D:\SteamLibrary\steamapps\common\Planet Coaster 2\PlanetCoaster2.exe',fast_load=True)
assert pe.FILE_HEADER.TimeDateStamp==0x6abfabee
md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_64);md.detail=True
k=ctypes.WinDLL('kernel32',use_last_error=True)
k.VirtualAlloc.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_uint32];k.VirtualAlloc.restype=ctypes.c_void_p
k.VirtualProtect.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.POINTER(ctypes.c_uint32)]
k.VirtualFree.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32]
size=0x3200000;image=k.VirtualAlloc(None,size,0x3000,4);assert image
constructor=(0x96c870,0x96d5fd)
for begin,end in [(0x968760,0x96893e),(0x968ae0,0x968cb0),constructor]:
    code=pe.get_data(begin,end-begin);ctypes.memmove(image+begin,code,len(code))
    if (begin,end)==constructor:continue
    for ins in md.disasm(code,begin):
        if ins.mnemonic=='call':assert ins.operands[0].imm in (0x9bf8a0,0x9bfa10)
        for op in ins.operands:
            if op.type==capstone.x86.X86_OP_MEM and op.mem.base==capstone.x86.X86_REG_RIP:
                rva=ins.address+ins.size+op.mem.disp
                assert 0<=rva<size-16
                ctypes.memmove(image+rva,pe.get_data(rva,16),16)
ctypes.memmove(image+0x2f98338,pe.get_data(0x2f98338,16),16)
# Record the requested storage count, skip storage that the lookup never reads.
ctypes.memmove(image+0x9bfa10,b'\x4c\x89\x01\xc3',4)
old=ctypes.c_uint32()
for page in [0x968000,0x9bf000]:assert k.VirtualProtect(image+page,4096,0x20,ctypes.byref(old))
# Register the copied functions' original unwind metadata for test-only SEH.
directory=pe.OPTIONAL_HEADER.DATA_DIRECTORY[3]
entries=[entry for entry in struct.iter_unpack('<III',pe.get_data(directory.VirtualAddress,directory.Size))
    if entry[0]==0x968760 or 0x968ae0<=entry[0]<0x968cb0]
for begin,end,unwind in entries:ctypes.memmove(image+unwind,pe.get_data(unwind,128),128)
runtime=(ctypes.c_uint32*(len(entries)*3))(*(v for entry in entries for v in entry))
k.RtlAddFunctionTable.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint64];k.RtlAddFunctionTable.restype=ctypes.c_ubyte
assert k.RtlAddFunctionTable(runtime,len(entries),image)
dll=ctypes.CDLL(str(Path('build/bridge_contract.dll').resolve()))
safe_initialize=dll.TestCrowdInitialize;safe_initialize.argtypes=[ctypes.c_void_p]*5;safe_initialize.restype=ctypes.c_int
fault=dll.TestNativeFaultAddress;fault.restype=ctypes.c_size_t
lookup=ctypes.WINFUNCTYPE(ctypes.c_void_p,*([ctypes.c_void_p]*4))(image+0x968ae0)
grid=ctypes.create_string_buffer(0x100)
def vector(*values):
    owner=ctypes.create_string_buffer(32)
    offset=(-ctypes.addressof(owner))%16
    array=(ctypes.c_float*4).from_buffer(owner,offset)
    array[:]=values;array.owner=owner
    return array
origin=vector(0,0,0,0);scale=vector(1,0,0,0)
def width_from_constructor():
    displacement=struct.unpack('<i',ctypes.string_at(image+0x96ce28+4,4))[0]
    return ctypes.c_float.from_address(image+0x96ce28+8+displacement).value
def create_grid():
    width=width_from_constructor()
    extent=vector(width,0,0,0)
    ctypes.memset(grid,0,len(grid))
    assert safe_initialize(image+0x968760,grid,origin,extent,scale),f'Initializer fault RVA {fault()-image:x}'
    return width,struct.unpack_from('<2I',grid.raw,0x60)
def inside(x,z):
    result=(ctypes.c_uint32*2)();position=(ctypes.c_float*4)(x,z,0,0)
    lookup(grid,result,position,None)
    return result[1]!=0xffffffff
assert create_grid()==(1024,(256,256))
assert inside(0,0) and inside(500,0)
for p in [(600,0),(-600,0),(0,600),(0,-600),(1500,1500)]:assert not inside(*p)
print('PASS actual stock Crowd lookup rejects points beyond +/-512')
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
assert changed and changed<={0x96ce28-constructor[0]+i for i in range(4,8)}
assert ctypes.string_at(image+0x2f98338,16)==pe.get_data(0x2f98338,16)
print('PASS actual enlarged Crowd lookup accepts exterior points up to +/-2048, rejects outside; only one load changed')
print('PASS cell metadata: 2 MiB -> 32 MiB at the stock scale; storage allocation itself is stubbed in this test')
k.RtlDeleteFunctionTable.argtypes=[ctypes.c_void_p]
assert k.RtlDeleteFunctionTable(runtime)
k.VirtualFree(image,0,0x8000)
