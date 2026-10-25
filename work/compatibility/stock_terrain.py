"""Read the game's own BHMP landscape. All access is read-only."""
import functools
import hashlib
import struct
import zlib
import numpy as np

COLLAR=0

class StockTerrain:
    def __init__(self,path,source_edges):
        packed=path.read_bytes()
        assert packed[:4]==b'BHMP'
        self.sha256=hashlib.sha256(packed).hexdigest()
        raw=zlib.decompress(packed[4:],wbits=-15)
        version,self.world_x,self.world_z,self.nx,self.nz,fmt=struct.unpack_from('<6I',raw)
        assert version==2 and fmt==2 and self.nx==self.nz==2048
        span,offset,self.water=struct.unpack_from('<3f',raw,24)
        assert raw[36] in (0,1)
        p=37+4*raw[36]
        count=struct.unpack_from('<I',raw,p)[0];p+=4
        assert count==self.nx*self.nz*2
        self.height=np.frombuffer(raw,dtype='<u2',count=self.nx*self.nz,offset=p).reshape(self.nz,self.nx).astype(np.float32)
        self.height*=span/65535;self.height+=offset
        p+=count
        count=struct.unpack_from('<I',raw,p)[0];p+=4
        assert count==self.nx*self.nz*8
        self.aux=np.frombuffer(raw,dtype=np.uint8,count=count,offset=p).reshape(self.nz,self.nx,8)
        p+=count
        materials=struct.unpack_from('<I',raw,p)[0];p+=4
        self.names=[]
        for _ in range(materials):
            length=struct.unpack_from('<H',raw,p)[0];p+=2
            self.names.append(raw[p:p+length].decode('utf-8'));p+=length
        assert p==len(raw) and materials==16
        # BHMP stores a material bit mask, unlike the voxel stream's four
        # packed indices. Weights belong to the set bits in ascending order.
        assert not np.any(self.aux[...,2:4])
        masks=self.aux[...,0].astype(np.uint16)|(self.aux[...,1].astype(np.uint16)<<8)
        self.material_lookup=np.zeros(65536,np.uint16)
        for value in np.unique(masks):
            mask=int(value)
            ids=[i for i in range(16) if mask>>i&1]
            assert len(ids)<=4,'Unexpected number of BHMP material slots'
            while len(ids)<4:ids.append(next(i for i in range(16) if i not in ids))
            self.material_lookup[mask]=sum(i<<(4*slot) for slot,i in enumerate(ids))
        self.edges=source_edges
        self.center_material=source_edges.center_material
        t=np.arange(-512,512)
        actual=np.stack((self.sample(-512,t)[0],self.sample(511,t)[0],
            self.sample(t,-512)[0],self.sample(t,511)[0]))
        self.edge_alignment_error=float(np.max(np.abs(actual-np.asarray(source_edges.heights))))
        assert self.edge_alignment_error<0.02,'Stock background does not align with the source park'

    def sample(self,x,z):
        X,Z=np.broadcast_arrays(np.asarray(x),np.asarray(z))
        u=(X/self.world_x+0.5)*self.nx
        v=(Z/self.world_z+0.5)*self.nz
        ix=np.floor(u).astype(np.int32);iz=np.floor(v).astype(np.int32)
        assert np.all((ix>=0)&(ix<self.nx-1)&(iz>=0)&(iz<self.nz-1))
        a=u-ix;b=v-iz
        h=(self.height[iz,ix]*(1-a)*(1-b)+self.height[iz,ix+1]*a*(1-b)
            +self.height[iz+1,ix]*(1-a)*b+self.height[iz+1,ix+1]*a*b)
        aux=self.aux[np.rint(v).astype(np.int32),np.rint(u).astype(np.int32)]
        mask=aux[...,0].astype(np.uint16)|(aux[...,1].astype(np.uint16)<<8)
        codes=self.material_lookup[mask]
        # Serialized voxel weights reconstruct w0 from the remaining three.
        weights=(aux[...,7],aux[...,6],aux[...,5])
        return h.astype(np.float32),weights,codes

    def exterior(self,x,z):
        return self.sample(x,z)

    @functools.lru_cache(maxsize=12)
    def root_data(self,x,z):
        return self.exterior(np.arange(x*512-1024,x*512-512)[:,None],np.arange(z*512-1024,z*512-512)[None,:])
