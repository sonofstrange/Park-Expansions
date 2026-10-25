"""Sample source edges and build exterior terrain without editing source cubes."""
from array import array
import functools
import math
import numpy as np

BASE=16

class SourceEdges:
    def __init__(self,v,density):
        tree=v.tree
        ends=array('I',[0])*len(tree)
        counts=array('I',[0])*len(tree)
        def index(p,side):
            start=p;mask=tree[p];p+=1;n=0
            if side==2:n=mask.bit_count()
            else:
                p+=1
                for i in range(8):
                    if mask>>i&1:p,k=index(p,side//2);n+=k
            ends[start]=p;counts[start]=n
            return p,n
        p=0
        for _ in range(4):p,_=index(p,512)
        field=np.empty((4,512,1024),np.int16)
        indices=np.full((4,512,1024),-1,np.int32)
        center=np.empty(512,np.int16)
        center_indices=np.full(512,-1,np.int32)
        def touches(x,z,s):
            return x==-512 or x+s==512 or z==-512 or z+s==512 or (x<=0<x+s and z<=0<z+s)
        def fill(x,y,z,s,sign):
            value=127 if sign else -127
            row=slice(y+256,y+256+s)
            for face,hit,t in ((0,x==-512,z),(1,x+s==512,z),(2,z==-512,x),(3,z+s==512,x)):
                if hit:
                    col=slice(t+512,t+512+s)
                    field[face,row,col]=value;indices[face,row,col]=-1
            if x<=0<x+s and z<=0<z+s:
                center[row]=value;center_indices[row]=-1
        def walk(p,s,x,y,z,sign,idx):
            fill(x,y,z,s,sign)
            mask=tree[p];p+=1
            if s==2:
                for i in range(8):
                    if mask>>i&1:
                        X=x+(i>>2);Y=y+((i>>1)&1);Z=z+(i&1)
                        value=density[idx];value=value if value<128 else value-256
                        for face,hit,t in ((0,X==-512,Z),(1,X==511,Z),(2,Z==-512,X),(3,Z==511,X)):
                            if hit:field[face,Y+256,t+512]=value;indices[face,Y+256,t+512]=idx
                        if X==0 and Z==0:center[Y+256]=value;center_indices[Y+256]=idx
                        idx+=1
                return
            flags=tree[p];p+=1;h=s//2
            for i in range(8):
                if mask>>i&1:
                    X=x+(i>>2)*h;Y=y+((i>>1)&1)*h;Z=z+(i&1)*h
                    if touches(X,Z,h):walk(p,h,X,Y,Z,(flags>>i)&1,idx)
                    idx+=counts[p];p=ends[p]
        p=0
        for root in range(4):
            walk(p,512,(root%2)*512-512,-256,(root//2)*512-512,v.roots[root][3],v.roots[root][1])
            p=ends[p]
        def surfaces(values,ids):
            crossing=(values[:-1]<0)&(values[1:]>=0)
            valid=crossing.any(axis=0)
            rows=510-crossing[::-1].argmax(axis=0)
            cols=np.arange(values.shape[1])
            low=values[rows,cols];high=values[rows+1,cols]
            height=rows-256-low/np.maximum(1,high-low)
            nearest=rows+(np.abs(high)<np.abs(low))
            sample=ids[nearest,cols]
            alternative=ids[rows+(nearest==rows),cols]
            sample=np.where(sample>=0,sample,alternative)
            if valid.any():height=np.interp(cols,cols[valid],height[valid])
            else:height[:]=BASE
            return height.astype(np.float32),sample,int((~valid).sum())
        self.heights=[];sample_ids=[];self.missing_columns=0
        for face in range(4):
            heights,samples,missing=surfaces(field[face],indices[face])
            self.heights.append(heights);sample_ids.extend(samples);self.missing_columns+=missing
        self.center_height,center_samples,_=surfaces(center[:,None],center_indices[:,None])
        sample_ids.extend(center_samples)
        sample_ids=np.asarray(sample_ids,np.int64)
        fallback=density.find(b'\x00')
        sample_ids=np.where(sample_ids>=0,sample_ids,max(0,fallback))
        n=v.samples
        weights=np.frombuffer(v.materials[:3*n],np.uint8).reshape(3,n)
        lengths=1+((weights[0]!=0)|(weights[1]!=0)).astype(np.uint8)
        offsets=np.cumsum(lengths,dtype=np.uint32)-lengths
        codes=np.frombuffer(v.materials[3*n:],np.uint8)
        selected=offsets[sample_ids]
        word=codes[selected].astype(np.uint16)
        word|=np.where(lengths[sample_ids]==2,codes[np.minimum(selected+1,len(codes)-1)].astype(np.uint16)<<8,0)
        w7,w6,w5=weights[:,sample_ids].astype(np.int16)
        dominant=np.stack(((255-w7-w6-w5)&255,w5,w6,w7)).argmax(axis=0)
        material=((word>>(dominant*4))&15).astype(np.uint8)
        self.materials=material[:-1].reshape(4,1024)
        self.center_material=int(material[-1])

def exterior_root(edges,root_x,root_z,root_y=2):
    heights,weights,codes=edges.root_data(root_x,root_z)
    # Mip bounds let the octree skip uniform regions without scanning voxels.
    minima={1:heights};maxima={1:heights}
    for side in (2,4,8,16,32,64,128,256,512):
        a=minima[side//2];b=maxima[side//2]
        minima[side]=np.minimum.reduce((a[::2,::2],a[1::2,::2],a[::2,1::2],a[1::2,1::2]))
        maxima[side]=np.maximum.reduce((b[::2,::2],b[1::2,::2],b[::2,1::2],b[1::2,1::2]))
    def uniform(side,sign):return (b'\x00' if side==2 else b'\x00\x00',b'',(b'',)*4,sign)
    @functools.lru_cache(None)
    def material_leaf(x,z):
        planes=tuple(bytes(int(w[x+(i>>2),z+(i&1)]) for i in range(8)) for w in weights)
        code=b''.join((int(codes[x+(i>>2),z+(i&1)])&
            (65535 if planes[0][i] or planes[1][i] else 255)).to_bytes(
                2 if planes[0][i] or planes[1][i] else 1,'little') for i in range(8))
        return planes+(code,)
    def combine(children,sign):
        flags=sum(child[3]<<i for i,child in enumerate(children))
        return (bytes((255,flags))+b''.join(c[0] for c in children),
            b''.join(c[1] for c in children),tuple(b''.join(c[2][j] for c in children) for j in range(4)),sign)
    def build(side,x,y,z):
        low=float(minima[side][x//side,z//side]);high=float(maxima[side][x//side,z//side])
        if y+side<=math.floor(low)-1:return uniform(side,0)
        if y>=math.ceil(high)+2:return uniform(side,1)
        sign=int(y>=float(heights[x,z]))
        if side==2:
            # -128 is outside the native signed-distance range. Native
            # terrain edits clamp to [-127,127], as do the source samples.
            d=bytes(max(-127,min(127,round((y+((i>>1)&1)-float(heights[x+(i>>2),z+(i&1)]))*127)))&255 for i in range(8))
            return b'\xff',d,material_leaf(x,z),sign
        h=side//2
        return combine([build(h,x+(i>>2)*h,y+((i>>1)&1)*h,z+(i&1)*h) for i in range(8)],sign)
    return build(512,0,root_y*512-1280,0)
