"""Verify 0.50 Sea edits using local stock instructions in private test buffers.

Does not attach to or start the game. No original executable is written.
Requires pefile/capstone and the BRIDGE_TEST build of the DLL.
"""
import ctypes
import re
import struct
import argparse
from pathlib import Path
import capstone
import pefile

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--game-exe',type=Path,default=Path(r'D:\SteamLibrary\steamapps\common\Planet Coaster 2\PlanetCoaster2.exe'))
exe=parser.parse_args().game_exe
pe=pefile.PE(str(exe),fast_load=True)
assert pe.FILE_HEADER.TimeDateStamp==0x6abfabee
assert pe.OPTIONAL_HEADER.SizeOfImage==0x130a4000
plan=(root/'work/compatibility/sea_raster_plan.h').read_text(encoding='utf-8')
patches=[]
for rva,length,a,b in re.findall(r'\{0x([0-9a-f]+),(\d+),\{([^}]+)\},\{([^}]+)\}\}',plan):
    parse=lambda x:bytes(int(v,16) for v in x.split(','))
    patches.append((int(rva,16),int(length),parse(a),parse(b)))
guards=[tuple(int(x,16) for x in row) for row in re.findall(
    r'\{0x([0-9a-f]+),0x([0-9a-f]+),0x([0-9a-f]+)ULL,0x([0-9a-f]+)ULL\}',plan)]
assert len(patches)==38 and len(guards)==2
size=max(g[1] for g in guards)+4096
dll=ctypes.CDLL(str(root/'build/bridge_contract.dll'))
apply=dll.TestSeaRaster;apply.argtypes=[ctypes.c_void_p,ctypes.c_size_t];apply.restype=ctypes.c_int
kernel=ctypes.WinDLL('kernel32',use_last_error=True)
kernel.VirtualAlloc.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_uint32]
kernel.VirtualAlloc.restype=ctypes.c_void_p
kernel.VirtualFree.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32]
kernel.VirtualProtect.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.POINTER(ctypes.c_uint32)]
image=kernel.VirtualAlloc(None,size,0x3000,4)
assert image
md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_64);md.detail=True
def reset():
    old=ctypes.c_uint32()
    assert kernel.VirtualProtect(image,size,4,ctypes.byref(old))
    for a,b,_,_ in guards:ctypes.memmove(image+a,pe.get_data(a,b-a),b-a)
def snapshot():return [ctypes.string_at(image+a,b-a) for a,b,_,_ in guards]
def fnv(data):
    h=14695981039346656037
    for b in data:h=((h^b)*1099511628211)&((1<<64)-1)
    return h
try:
    reset()
    before=snapshot()
    assert apply(image,100)==0 and snapshot()==before,'Truncated image must not be changed'
    for g,code in zip(guards,before):assert fnv(code)==g[2]
    # Corrupt the last function, then a non-patch byte: neither may allow partial writes.
    for rva in [patches[-1][0],guards[1][0]+1]:
        reset();ctypes.c_ubyte.from_address(image+rva).value^=1;bad=snapshot()
        assert apply(image,size)==0 and snapshot()==bad
    reset()
    # Read-only pages exercise the same permission transaction used in the host.
    old=ctypes.c_uint32();assert kernel.VirtualProtect(image,size,2,ctypes.byref(old))
    assert apply(image,size)==1
    after=snapshot()
    for g,code in zip(guards,after):assert fnv(code)==g[3]
    for rva,n,a,b in patches:
        assert pe.get_data(rva,n)==a and ctypes.string_at(image+rva,n)==b
        original=list(md.disasm(a,rva));changed=list(md.disasm(b,rva))
        assert len(original)==len(changed)==1 and original[0].size==changed[0].size==n
        assert original[0].mnemonic==changed[0].mnemonic
    assert apply(image,size)==1 and snapshot()==after,'Repeated initialization must be idempotent'
    # Verify original 1024, old 2048 and new 4096 fields all fit, including rectangular worlds.
    for width in [1024,2048,4096]:
        for depth in [1024,2048,4096]:
            x0=2048-width//2;z0=2048-depth//2
            first=z0*4096+x0;last=(z0+depth-1)*4096+x0+width-1
            assert 0<=first<=last<4096**2
    assert (1024-4096//2)*2048+(1024-4096//2)==-2098176,'Must reproduce 0.49 dump index'
    values={rva:list(md.disasm(b,rva))[0] for rva,n,a,b in patches}
    imm=lambda rva:values[rva].operands[-1].imm
    assert imm(0x117cc73)==4096**2 and imm(0x117cc59)==4096**2*4
    assert imm(0x117ccb7)==2048 and values[0x117cd85].operands[-1].mem.disp==2048
    for rva in [0x117cea7,0x117d02c,0x117d0d5,0x117d15e,0x117d1fc,0x117d306]:assert imm(rva)==12
    assert imm(0x117e7ab)==imm(0x117e800)==4096
    assert struct.unpack('<f',struct.pack('<I',imm(0x117e919)))[0]==4096
    assert struct.unpack('<f',struct.pack('<I',imm(0x117e920)))[0]==1/4096
    print('PASS 38 exact instruction edits; full-function guards; no partial writes; idempotence; CPU/GPU sizes; old/new world indexing')
finally:
    kernel.VirtualFree(image,0,0x8000)
