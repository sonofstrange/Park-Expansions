import ctypes
from pathlib import Path
root=Path(__file__).resolve().parents[1]
dll=ctypes.CDLL(str(root/'build/bridge_contract.dll'))
check=dll.TestArgumentContract;check.argtypes=[ctypes.c_void_p];check.restype=ctypes.c_int
state=ctypes.create_string_buffer(64);ci=ctypes.create_string_buffer(32);stack=ctypes.create_string_buffer(24*5)
def pointer(address,value):ctypes.c_void_p.from_address(address).value=value
pointer(ctypes.addressof(state)+0x20,ctypes.addressof(ci));pointer(ctypes.addressof(ci),ctypes.addressof(stack))
pointer(ctypes.addressof(state)+0x10,ctypes.addressof(stack)+len(stack))
def arguments(values):
 strings=[]
 for index,value in enumerate(values,1):
  encoded=value.encode();text=ctypes.create_string_buffer(24+len(encoded)+1);text[11]=bytes([len(encoded)])
  ctypes.memmove(ctypes.addressof(text)+24,encoded,len(encoded))
  item=ctypes.addressof(stack)+24*index;pointer(item,ctypes.addressof(text));ctypes.c_uint.from_address(item+16).value=0x44
  strings.append(text)
 return check(ctypes.addressof(state))
assert arguments(['__prepare_map__','','taiga','123-456'])==0
assert arguments(['__prepare_map__','Terrain preparation','taiga','123-456'])==1
print('PASS real Win64 bridge reader rejects 0.36 empty name and accepts corrected four strings')
