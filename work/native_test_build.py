"""Verified address mapping for private native tests on either supported EXE."""
import ctypes
updated=False
latest=False
def identify(pe):
    global updated,latest
    pair=(pe.FILE_HEADER.TimeDateStamp,pe.OPTIONAL_HEADER.SizeOfImage)
    assert pair in ((0x6abfabee,0x130a4000),(0x6ae11c9a,0x12187000),(0x6ae8f335,0x12343000)),pair
    latest=pair[0]==0x6ae8f335
    updated=pair[0] in (0x6ae11c9a,0x6ae8f335)
    return updated

def select(dll,pe):
    choose=dll.TestSelectGameBuild
    choose.argtypes=[ctypes.c_uint32,ctypes.c_uint32];choose.restype=ctypes.c_int
    assert choose(0,pe.OPTIONAL_HEADER.SizeOfImage)==0
    assert choose(pe.FILE_HEADER.TimeDateStamp,pe.OPTIONAL_HEADER.SizeOfImage)==1

def previous_rva(old):
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

def rva(old):
    value=previous_rva(old)
    if not latest:return value
    constants={0x2fe7170:0x2fe8308,0x3131230:0x3132480,0x3130cd0:0x3131f20,
        0x169a000:0x169b000,0x1a61000:0x1a62000,0x1a63000:0x1a63000,
        0x99b000:0x99c000,0x9ea000:0x9eb000}
    if value in constants:return constants[value]
    if 0x11c72d0<=value<=0x11c92d5:return value+0xe50
    if 0x169a650<=value<=0x169a945:return value+0xad0
    if 0x1a61ad0<=value<=0x1a6361a:return value+0xb70
    if 0x992e70<=value<=0x99bc1a:return value+0xe70
    if value in (0x9ea4a0,0x9ea610):return value+0xe90
    raise AssertionError(hex(value))
