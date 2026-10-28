"""Profile selection never borrows a matching park from another account."""
import ctypes
import os
from pathlib import Path
import tempfile

bridge=ctypes.CDLL(str(Path("build/bridge_contract.dll").resolve()))
find=bridge.TestFindSave
find.argtypes=[ctypes.c_wchar_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_wchar_p,ctypes.c_size_t]
find.restype=ctypes.c_int
with tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp)
    def put(profile,name,mtime):
        path=root/profile/"Saves"/name
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(b"fixture")
        os.utime(path,(mtime,mtime))
        return path
    old=put("76561199389313053","SonofPark-A80BF5DB.park2",200)
    current=put("76561198765005009","SonofPark-61E95D1C.park2",100)
    put("76561198765005009","RecentPark.park2",300)
    put("NotAnAccount","SonofPark.park2",400)
    def lookup(identifier,name):
        out=ctypes.create_unicode_buffer(32768)
        result=find(str(root),identifier.encode(),name.encode(),out,len(out))
        assert result>=0
        return Path(out.value) if result else None
    assert lookup("","SonofPark")==current
    assert lookup("61E95D1C","")==current
    assert lookup("A80BF5DB","") is None,"Cross-account ID fallback"
    assert lookup("","MissingPark") is None,"Cross-account name fallback"
    assert lookup("","").name=="RecentPark.park2"
print("PASS profile-local save selection, missing save and invalid account directory")
