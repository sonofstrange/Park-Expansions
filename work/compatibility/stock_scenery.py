"""Read original backdrop placements, without modifying or redistributing game assets.

This deliberately accepts only PC2's small, single-STATIC biome world archives.
Unsupported layouts are rejected before any placement data reaches the game.
"""
from pathlib import Path
import hashlib, json, math, os, re, struct, zlib
import numpy as np

VERSION = 1
CLUSTERS = {
    'NAT_Tree_Conifer_Larch_European_Cluster_01',
    'NAT_Tree_Conifer_Larch_European_Cluster_02',
    'NAT_Tree_Conifer_Pine_Aleppo_Cluster_01',
    'NAT_Tree_Conifer_Pine_Aleppo_Cluster_02',
    'NAT_Tree_Broadleaf_Olive_Cluster_01',
    'NAT_Tree_Broadleaf_Olive_Cluster_02',
    'NAT_Bush_Creosote_Flowerless_Cluster_01',
}


def sample_height(height,world_x,world_z,x,z):
    nz,nx=height.shape
    u=(np.asarray(x)/world_x+0.5)*nx
    v=(np.asarray(z)/world_z+0.5)*nz
    ix=np.floor(u).astype(int);iz=np.floor(v).astype(int)
    if not np.all((ix>=0)&(ix<nx-1)&(iz>=0)&(iz<nz-1)):
        raise ValueError('Scenery position lies outside original landscape data')
    a=u-ix;b=v-iz
    return (height[iz,ix]*(1-a)*(1-b)+height[iz,ix+1]*a*(1-b)+
            height[iz+1,ix]*(1-a)*b+height[iz+1,ix+1]*a*b)


def baked_heights(path):
    packed=Path(path).read_bytes()
    if packed[:4]!=b'BHMP':raise ValueError('Unsupported original landscape data')
    raw=zlib.decompress(packed[4:],-15)
    version,wx,wz,nx,nz,fmt=struct.unpack_from('<6I',raw)
    if (version,nx,nz,fmt)!=(2,2048,2048,2) or raw[36] not in (0,1):
        raise ValueError('Unsupported original landscape height format')
    span,offset=struct.unpack_from('<2f',raw,24)
    p=37+4*raw[36]
    if struct.unpack_from('<I',raw,p)[0]!=nx*nz*2:raise ValueError('Invalid original height count')
    height=np.frombuffer(raw,dtype='<u2',count=nx*nz,offset=p+4).reshape(nz,nx).astype(np.float64)
    height*=span/65535; height+=offset
    return height,wx,wz


def placements(path,baked_heightmap=None):
    data = Path(path).read_bytes()
    def require(test):
        if not test: raise ValueError('Unsupported original scenery archive layout')
    require(data[:8] == b'FRES\x01\x14\x00\x01')
    require((struct.unpack_from('<I', data, 8)[0] >> 7) & 7 == 1)
    # PC2 OVL fixed header, followed by names, MIME records and file entries.
    ovs, names_size, zero, aux = struct.unpack_from('<4I', data, 12)
    included, mimes = struct.unpack_from('<2H', data, 28)
    files, files2, dependencies, archives = struct.unpack_from('<4I', data, 32)
    streams = struct.unpack_from('<I', data, 64)[0]
    archive_names_size = struct.unpack_from('<I', data, 80)[0]
    triplets = struct.unpack_from('<I', data, 92)[0]
    require(ovs == 0 and archives == 1 and files == files2 == 4 and mimes == 3)
    require(not included and not dependencies and not streams and aux == 1)
    p = 144 + names_size + mimes * 32 + ((triplets * 3 + 3) & ~3) + files * 12
    require(data[p:p+archive_names_size].rstrip(b'\0') == b'STATIC')
    p += archive_names_size
    values = struct.unpack_from('<4I2H7IQ3I', data, p)
    (name, pool_offset, stream_offset, pools, datas, pool_groups, buffer_groups,
     buffers, fragments, roots, read_start, set_size, compressed_size,
     uncompressed_size, pools_start, pools_end, ovs_offset) = values
    require((pools, datas, pool_groups, buffer_groups, buffers, fragments, roots, set_size)
            == (2, 3, 2, 3, 5, 0, 4, 16))
    require(not any((name, pool_offset, stream_offset, read_start, pools_start, ovs_offset)))
    eof = p + 68 + aux * 12 + archives * 8
    require(eof + compressed_size == len(data) and uncompressed_size < 64 * 1024 * 1024)
    decoder = zlib.decompressobj()
    raw = decoder.decompress(data[eof:eof+compressed_size], uncompressed_size+1)
    require(len(raw) == uncompressed_size and decoder.eof and
            not decoder.unused_data and not decoder.unconsumed_tail)
    pool_table = pool_groups * 4
    pool_sizes = [struct.unpack_from('<I', raw, pool_table + i*32 + 8)[0] for i in range(pools)]
    require(sum(pool_sizes) == pools_end)
    buffer_table = pool_table + pools*32 + datas*32
    buffer_records = [struct.unpack_from('<2I', raw, buffer_table+i*8) for i in range(buffers)]
    root_table = buffer_table + buffers*8 + buffer_groups*32
    root_records = [struct.unpack_from('<2IiI', raw, root_table+i*16) for i in range(roots)]
    matches = [r for r in root_records if r[1] == 3059885504]  # djb2("voxelskirt")
    require(len(matches) == 1)
    file_id, _, pool_id, offset = matches[0]
    require(0 <= pool_id < pools)
    pool_start = root_table + roots*16 + set_size
    header = pool_start + sum(pool_sizes[:pool_id]) + offset
    require(offset + 120 <= pool_sizes[pool_id])
    _, byte_count, nx, nz, scale = struct.unpack_from('<4Qf', raw, header)
    require(nx == nz == 2048 and scale == 4)
    # Buffer IO order is buffer index first, then file index. These archives
    # contain two empty/300-byte FDB pairs followed by one voxelskirt buffer.
    require([r[0] for r in buffer_records[:4]] == [0, 0, 300, 300])
    require(buffer_records[4] == (byte_count, file_id))
    body_start = pool_start + sum(pool_sizes) + 600
    body = raw[body_start:body_start+byte_count]
    require(len(body) == byte_count and body_start + byte_count == len(raw))
    groups_offset, groups_count = struct.unpack_from('<2Q', raw, header+72)
    names_offset, names_count = struct.unpack_from('<2Q', raw, header+104)
    require(0 < groups_count < 100 and names_count < 1000)
    def span(offset, count, size):
        require(0 <= offset <= len(body) and 0 <= count <= (len(body)-offset)//size)
    span(names_offset, names_count, 8)
    names = []
    for i in range(names_count):
        start = struct.unpack_from('<Q', body, names_offset+i*8)[0]
        span(start, 1, 1)
        end = body.find(b'\0', start, min(start+256, len(body)))
        require(end >= start)
        names.append(body[start:end].decode('ascii'))
    target=None
    if baked_heightmap is not None:
        layer_offset,layer_count=struct.unpack_from('<2Q',raw,header+40)
        require(layer_count==1)
        span(layer_offset,layer_count,32)
        name_id,dtype,height_offset,height_bytes=struct.unpack_from('<4Q',body,layer_offset)
        require(name_id<len(names) and names[name_id]=='height' and dtype==2 and height_bytes==nx*nz*4)
        span(height_offset,nx*nz,4)
        original_height=np.frombuffer(body,dtype='<f4',count=nx*nz,offset=height_offset).reshape(nz,nx)
        target=baked_heights(baked_heightmap)
    span(groups_offset, groups_count, 32)
    groups = []
    for i in range(groups_count):
        offset, count, name_id, _, _ = struct.unpack_from('<3Q2i', body, groups_offset+i*32)
        require(name_id < len(names) and count < 100000)
        span(offset, count, 16)
        prefab = names[name_id]
        require(re.fullmatch(r'NAT_[A-Za-z0-9_]+_Skirt(?:NoShadow)?', prefab) is not None)
        resource = re.sub(r'_Skirt(?:NoShadow)?$', '', prefab)
        if resource in CLUSTERS: resource = 'PE_' + resource
        instances = []
        for j in range(count):
            row = struct.unpack_from('<4f', body, offset+j*16)
            require(all(math.isfinite(v) for v in row))
            x, y, z, angle = row
            # Leave the entire original editable square and outer backdrop alone.
            if 512 <= max(abs(x), abs(z)) < 1020:
                instances.append(row)
        if instances: groups.append(dict(resource=resource, prefab=prefab, instances=instances))
    if target is not None:
        height,wx,wz=target
        for group in groups:
            rows=np.asarray(group['instances'],dtype=np.float64)
            original_ground=sample_height(original_height,nx*scale,nz*scale,rows[:,0],rows[:,2])
            # The live Sandbox uses its baked landscape, not the world OVL's
            # authoring height layer (some biome authoring layers are flat Y512).
            # Preserve X/Z, heading and the tree's offset above its source ground.
            rows[:,1]+=sample_height(height,wx,wz,rows[:,0],rows[:,2])-original_ground
            group['instances']=[tuple(row) for row in rows.tolist()]
    return groups


def ensure_scenery(mod_dir, name, game_dir):
    biome = name.removesuffix('Sandbox')
    source = game_dir/'Win64/ovldata/Content0/Worlds'/(biome+'World')/(biome+'World.ovl')
    baked = game_dir/'TerrainSkirts'/name/(name+'.bakedHeightMap')
    fingerprint = hashlib.sha256(hashlib.sha256(source.read_bytes()).digest()+hashlib.sha256(baked.read_bytes()).digest()).hexdigest()
    folder = mod_dir/'Maps'
    output = folder/(name+'.decor.lua')
    manifest = folder/(name+'.decor.json')
    try:
        saved = json.loads(manifest.read_text(encoding='utf-8'))
        if (saved['version'] == VERSION and saved['source'] == fingerprint and
                saved['output'] == hashlib.sha256(output.read_bytes()).hexdigest()):
            return saved
    except (OSError, ValueError, KeyError, TypeError): pass
    groups = placements(source,baked)
    # Only numbers and strictly validated game identifiers enter this Lua file.
    chunks = ['return {version=1,source="'+fingerprint+'",groups={\n']
    for group in groups:
        chunks.append('{resource="'+group['resource']+'",instances={\n')
        chunks.extend('{'+','.join(repr(v) for v in row)+'},\n' for row in group['instances'])
        chunks.append('}},\n')
    chunks.append('}}\n')
    data = ''.join(chunks).encode('utf-8')
    temp = output.with_suffix('.lua.pending'); temp.write_bytes(data)
    os.replace(temp, output)
    report = dict(version=VERSION, source=fingerprint,
                  output=hashlib.sha256(data).hexdigest(),
                  count=sum(len(g['instances']) for g in groups), groups=len(groups))
    temp = manifest.with_suffix('.json.pending')
    temp.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8', newline='\n')
    os.replace(temp, manifest)
    return report
