"""Verified address mapping for private native tests on either supported EXE."""
import ctypes
updated=False
def identify(pe):
    global updated
    pair=(pe.FILE_HEADER.TimeDateStamp,pe.OPTIONAL_HEADER.SizeOfImage)
    assert pair in ((0x6abfabee,0x130a4000),(0x6ae11c9a,0x12187000)),pair
    updated=pair[0]==0x6ae11c9a
    return updated

def select(dll,pe):
    choose=dll.TestSelectGameBuild
    choose.argtypes=[ctypes.c_uint32,ctypes.c_uint32];choose.restype=ctypes.c_int
    assert choose(0,pe.OPTIONAL_HEADER.SizeOfImage)==0
    assert choose(pe.FILE_HEADER.TimeDateStamp,pe.OPTIONAL_HEADER.SizeOfImage)==1

def rva(old):
    if not updated:return old
    constants={0x2f98338:0x2fe7170,0x30de520:0x3131230,0x30ddfc0:0x3130cd0,
        0x164c000:0x169a000,0x1a13000:0x1a61000,0x1a15000:0x1a63000,
        0x971000:0x99b000,0x9bf000:0x9ea000}
    if old in constants:return constants[old]
    if 0x117cb20<=old<=0x117eb25:return old+0x4a7b0
    if 0x164c500<=old<=0x164c7f5:return old+0x4e150
    if 0x1a13990<=old<=0x1a154da:return old+0x4e140
    if 0x968760<=old<=0x97150a:return old+0x2a710
    if old in (0x9bf8a0,0x9bfa10):return old+0x2ac00
    raise AssertionError(hex(old))
