"""Exact game save-token identity, duplicate profiles and no name fallback."""
import ctypes,os,tempfile
from pathlib import Path
bridge=ctypes.CDLL(str(Path("build/bridge_contract.dll").resolve()))
find=bridge.TestFindSave
find.argtypes=[ctypes.c_wchar_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_wchar_p,ctypes.c_size_t];find.restype=ctypes.c_int
def identifier(filename):
    h=5381
    for b in filename.encode('utf-8'):h=(h*33+(b if b<128 else b-256))&0xffffffff
    return str(h)
# Recorded ID from the actual game's GetSaveIdentifier binding.
assert identifier('SonofPark-61E95D1C.park2')=='3702277285'
with tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp)
    def put(profile,name,mtime):
        p=root/profile/"Saves"/name;p.parent.mkdir(parents=True,exist_ok=True)
        p.write_bytes(b"fixture");os.utime(p,(mtime,mtime));return p
    def lookup(id,name=''):
        out=ctypes.create_unicode_buffer(32768)
        result=find(str(root),id.encode(),name.encode(),out,len(out));assert result>=0
        return Path(out.value) if result else None
    scoped=bridge.TestFindSaveForAccount
    scoped.argtypes=[ctypes.c_wchar_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_wchar_p,ctypes.c_size_t];scoped.restype=ctypes.c_int
    def lookup_account(id,account):
        out=ctypes.create_unicode_buffer(32768)
        result=scoped(str(root),id.encode(),b"SonofPark",account.encode(),out,len(out));assert result>=0
        return Path(out.value)if result else None
    first='76561198765005009';second='76561199389313053'
    old=put(second,'SonofPark-A80BF5DB.park2',400)
    chosen=put(first,'SonofPark-61E95D1C.park2',100)
    put(first,'SonofPark Extra-1733AD85.park2',500)
    put(first,'SonofPark-25CE0704.park2',600)
    put('NotAnAccount','SonofPark-61E95D1C.park2',1000)
    assert lookup(identifier(chosen.name),'SonofPark')==chosen
    assert lookup(identifier(old.name),'SonofPark')==old
    assert lookup('61E95D1C')==chosen
    assert lookup(chosen.name)==chosen
    for id in ('','Missing','4294967296','999999999999999999999999999999999999'):
        assert lookup(id,'SonofPark')is None
    assert lookup('DEADBEEF','SonofPark')is None
    assert lookup('61E95D1','SonofPark')is None
    print('PASS real decimal token hash selects exact file; latest profile/name/prefix/substring cannot substitute a park')
    duplicate=put(second,chosen.name,1000)
    assert lookup(identifier(chosen.name),'SonofPark')is None
    assert lookup('61E95D1C')is None
    assert lookup_account(identifier(chosen.name),first)==chosen
    assert lookup_account(identifier(chosen.name),second)==duplicate
    assert lookup_account(identifier(old.name),first)is None
    assert lookup_account(identifier(chosen.name),'76561190000000000')is None
    for bad in ('../'+second,'NotAnAccount','0'):
        assert lookup_account(identifier(chosen.name),bad)is None
    print('PASS authoritative Steam account resolves duplicate filenames; no cross-account fallback or date guessing')
    duplicate.unlink()
    assert lookup(identifier(chosen.name),'Completely different display name')==chosen
    a=put(first,'Ab-1234ABCD.park2',200)
    b=put(first,'BA-1234ABCD.park2',300)
    assert identifier(a.name)==identifier(b.name)
    assert lookup(identifier(a.name))is None
    assert lookup_account(identifier(a.name),first)is None
    assert lookup('1234ABCD')is None
    unicode=put(first,'Парк-ABCDEF01.park2',100)
    assert lookup(identifier(unicode.name))==unicode
    assert lookup('', '')is None
    print('PASS duplicate accounts, true hash collisions, Unicode filenames and empty identifiers fail safely or match exactly')
