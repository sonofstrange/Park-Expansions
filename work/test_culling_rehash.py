"""Execute the original culling insertion instructions against a moved bucket table.
Runs only in private test-process memory. The retired table stays allocated so
that the original defect is observed safely as a stale write instead of an AV.
"""
import ctypes as c,struct
from pathlib import Path
import pefile,capstone
pe=pefile.PE(r'D:/SteamLibrary/steamapps/common/Planet Coaster 2/PlanetCoaster2.exe',fast_load=True)
from native_test_build import identify,select,rva as game_rva
updated=identify(pe)
k=c.WinDLL('kernel32',use_last_error=True)
k.VirtualAlloc.argtypes=[c.c_void_p,c.c_size_t,c.c_uint32,c.c_uint32];k.VirtualAlloc.restype=c.c_void_p
k.VirtualProtect.argtypes=[c.c_void_p,c.c_size_t,c.c_uint32,c.POINTER(c.c_uint32)]
k.VirtualFree.argtypes=[c.c_void_p,c.c_size_t,c.c_uint32]
k.FlushInstructionCache.argtypes=[c.c_void_p,c.c_void_p,c.c_size_t]
size=0x2200000;image=k.VirtualAlloc(None,size,0x3000,4);assert image
site=game_rva(0x1a153e8);start=game_rva(0x1a15020);end=game_rva(0x1a154da)
for a,b in [(start,end),(game_rva(0x1a13990),game_rva(0x1a13a5d))]:c.memmove(image+a,pe.get_data(a,b-a),b-a)
def put(address,data):
 old=c.c_uint32();assert k.VirtualProtect(address,len(data),0x40,c.byref(old))
 c.memmove(address,data,len(data));assert k.FlushInstructionCache(c.c_void_p(-1),address,len(data))
 ignored=c.c_uint32();assert k.VirtualProtect(address,len(data),old.value,c.byref(ignored))
def rel(from_rva,to_rva):return struct.pack('<i',to_rva-from_rva-5)
entry=bytes.fromhex('575641564883ec204c8bf1488bf2498bf8')+b'\xe9'+rel(0x1011,site)
# Push rdi/rsi/r14, reserve shadow space, set the engine's live registers.
assert len(entry)==22
c.memmove(image+0x1000,entry,len(entry))
exit_code=bytes.fromhex('4883c420415e5e5fc3');c.memmove(image+0x1040,exit_code,len(exit_code))
old=c.c_uint32()
for page in {0x1000,game_rva(0x1a13990)&~4095,*range(start&~4095,end,4096)}:assert k.VirtualProtect(image+page,4096,0x20,c.byref(old))
execute=c.WINFUNCTYPE(c.c_void_p,c.c_void_p,c.c_void_p,c.c_void_p)(image+0x1000)
hash_key=c.WINFUNCTYPE(c.c_uint32,c.c_void_p)(image+game_rva(0x1a13990))
manager=c.create_string_buffer(0x160);node=c.create_string_buffer(0x30);existing=c.create_string_buffer(0x30)
retired=(c.c_void_p*7)();current=(c.c_void_p*29)()
struct.pack_into('<QQ',manager,0x128,c.addressof(current),len(current))
key=(700,-20,580,2);struct.pack_into('<4i',node,8,*key)
hash_value=hash_key(c.addressof(node)+8);old_i=hash_value%len(retired);new_i=hash_value%len(current)
old_head=c.addressof(retired)+old_i*8;new_head=c.addressof(existing)
retired[old_i]=old_head;current[new_i]=new_head
# Exit after the actual 16-byte insertion sequence rather than running the rest
# of the game's renderer. Restore these five bytes before validating the patch.
continuation=pe.get_data(site+16,5)
put(image+site+16,b'\xe9'+rel(site+16,0x1040))
execute(manager,node,c.addressof(retired)+old_i*8)
assert retired[old_i]==c.addressof(node) and current[new_i]==new_head
assert struct.unpack_from('<Q',node)[0]==old_head
print('PASS original engine sequence writes the retired bucket after recursive rehash')
put(image+site+16,continuation)
dll=c.CDLL(str(Path('build/bridge_contract.dll').resolve()))
select(dll,pe)
configure=dll.TestCullingRehash;configure.argtypes=[c.c_void_p,c.c_size_t];configure.restype=c.c_int
assert configure(image,100)==0
stock=c.string_at(image+start,end-start)
put(image+start+1,bytes([stock[1]^1]));bad=c.string_at(image+start,end-start)
assert configure(image,size)==0 and c.string_at(image+start,end-start)==bad
put(image+start,stock)
assert configure(image,size)==1 and configure(image,size)==1
patched=c.string_at(image+start,end-start)
assert all(a==b or site-start<=i<site-start+16 for i,(a,b)in enumerate(zip(stock,patched)))
helper=image+site+5+struct.unpack('<i',c.string_at(image+site+1,4))[0]
md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_64);md.detail=True
for ins in md.disasm(c.string_at(helper,256),helper):
 assert ins.mnemonic not in ('call','push','pop','jmp','sub') or ins.mnemonic=='sub' and 'rsp' not in ins.op_str
 assert not any(o.type==capstone.x86.X86_OP_MEM and o.mem.base==capstone.x86.X86_REG_RIP for o in ins.operands)
 if ins.mnemonic=='ret':break
else:raise AssertionError('No leaf helper return')
put(image+site+16,b'\xe9'+rel(site+16,0x1040))
for x in range(-20,21):
 struct.pack_into('<4i',node,8,x*113,7-x,x*47,x%5)
 value=hash_key(c.addressof(node)+8);old_i=value%len(retired);new_i=value%len(current)
 old_head=c.addressof(retired)+old_i*8;retired[old_i]=old_head;current[new_i]=new_head
 execute(manager,node,c.addressof(retired)+old_i*8)
 assert current[new_i]==c.addressof(node) and retired[old_i]==old_head
 assert struct.unpack_from('<Q',node)[0]==new_head,'Existing collision chain was lost'
print('PASS patched insertion refreshes both bucket pointer and capacity; collision chains retained')
assert c.string_at(image+game_rva(0x1a13990),0xcd)==pe.get_data(game_rva(0x1a13990),0xcd)
print('PASS exact build guards, idempotence, unchanged hash, 16-byte patch and leaf helper')
k.VirtualFree(image,0,0x8000)
