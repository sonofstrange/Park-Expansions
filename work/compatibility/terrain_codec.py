from pathlib import Path
import hashlib, math, re, zlib, itertools

def uint(data, pos):
    tag = data[pos]
    if tag < 0x40:
        return tag, pos+1
    if 0xc0 <= tag <= 0xef:
        if tag & 8:
            raise ValueError(f'Negative scalar used as size at {pos:#x}')
        n = (tag >> 4)-11
        return ((tag & 7) << (8*n)) | int.from_bytes(data[pos+1:pos+1+n], 'big'), pos+1+n
    if tag == 0xf0:
        return int.from_bytes(data[pos+1:pos+5], 'big'), pos+5
    raise ValueError(f'Unexpected unsigned scalar {tag:#x} at {pos:#x}')

def put_uint(value):
    assert 0 <= value <= 0xffffffff
    if value < 64:
        return bytes([value])
    for n in range(1,4):
        # Bit 3 of the tag is the sign, not another magnitude bit.
        # Native encoder thresholds: 0x800, 0x80000, 0x8000000.
        if value < 1 << (8*n+3):
            return bytes([((11+n) << 4) | (value >> (8*n))]) + (value & ((1 << (8*n))-1)).to_bytes(n,'big')
    return b'\xf0' + value.to_bytes(4,'big')

def digest(data):
    return hashlib.sha256(data).hexdigest()

def unpack(path):
    data = path.read_bytes()
    assert data[:17] in (b'[PlCo2WoSa][COMP]', b'[PlCo2TnSa][COMP]')
    dec = zlib.decompressobj(-15)
    raw = dec.decompress(data[17:]) + dec.flush()
    assert dec.eof and not dec.unused_data
    return data[:17], raw

def clients(data):
    start = data.index(b'ClientSizes>')+len(b'ClientSizes>')
    count,pos = uint(data,start)
    sizes=[]
    for _ in range(count):
        value,pos=uint(data,pos)
        sizes.append(value)
    blocks = list(re.finditer(rb'(?:Header|Client)Client>>\xf3([^\0]{1,100})\0',data))
    assert len(blocks)==count
    result=[]
    for size,match in zip(sizes,blocks):
        version,version_end=uint(data,match.end())
        end=version_end+size
        assert data[end:end+8]==b'<<Client', match.group(1)
        result.append((match.group(1).decode(), match.end(), version_end, end))
    return start,pos,sizes,result

class Volume:
    def __init__(self, data):
        self.data=data
        p=0
        self.version,p=uint(data,p)
        assert self.version==5
        self.shape=[]
        for _ in range(3):
            n,p=uint(data,p);self.shape.append(n)
        self.block,p=uint(data,p)
        assert self.block==512
        scale,p=uint(data,p)
        assert scale==1, 'Only one-metre voxels supported'
        self.header_end=p
        assert data[p]==0, 'Partial voxel volumes are unsupported'
        p+=1
        root_count=math.prod(self.shape)
        self.signs=data[p:p+(root_count+7)//8];p+=len(self.signs)
        tree_size,p=uint(data,p)
        self.samples,p=uint(data,p)
        self.tree=data[p:p+tree_size];p+=tree_size
        assert len(self.tree)==tree_size
        self.deltas=data[p:p+self.samples];p+=self.samples
        assert len(self.deltas)==self.samples
        # Remaining material encoding is retained as opaque bytes, unchanged.
        self.materials=data[p:]
        assert self.materials
        index=0
        samples=0
        self.roots=[]
        def walk(side):
            nonlocal index,samples
            assert index < len(self.tree)
            mask=self.tree[index];index+=1
            if side==2:
                samples+=mask.bit_count()
                return
            flags=self.tree[index];index+=1
            assert flags & ~mask==0
            for child in range(8):
                if mask >> child & 1:
                    walk(side//2)
        for root in range(root_count):
            a,b=index,samples
            walk(self.block)
            self.roots.append((self.tree[a:index],b,samples,(self.signs[root//8] >> (root%8)) & 1))
        assert index==len(self.tree), (index,len(self.tree))
        assert samples==self.samples, (samples,self.samples)

def decode_density(deltas):
    return bytes(value & 255 for value in itertools.accumulate(deltas))

def encode_density(values):
    result=bytearray(len(values))
    previous=0
    for i,value in enumerate(values):
        result[i]=(value-previous)&255
        previous=value
    return bytes(result)

def material_parts(v):
    n=v.samples
    planes=tuple(v.materials[i*n:(i+1)*n] for i in range(3))
    codes=v.materials[3*n:]
    parts=[];p=0
    for _,begin,end,_ in v.roots:
        size=end-begin+sum(a!=0 or b!=0 for a,b in zip(planes[0][begin:end],planes[1][begin:end]))
        parts.append(tuple(plane[begin:end] for plane in planes)+(codes[p:p+size],))
        p+=size
    assert p==len(codes), 'Unexpected material stream layout'
    return parts
