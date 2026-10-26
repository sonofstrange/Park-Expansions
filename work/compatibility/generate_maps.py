"""Generate preserved 2048 m or experimental 4096 m terrain on demand."""
from pathlib import Path
import hashlib, json, os, struct, zlib
from terrain_codec import Volume, unpack, clients, put_uint, digest, decode_density, encode_density, material_parts
from stock_terrain import COLLAR

GENERATOR_VERSION = 36
BIOMES = {n.lower(): n+'Sandbox' for n in ('Temperate','Tropical','Taiga','Mediterranean')}

def extend(blob,name,game_dir,progress,size=2048):
    if size not in (2048,4096): raise ValueError("Unsupported terrain volume")
    width=size//512;inner=width//2-1;total=width*9*width
    from terrain_transition import SourceEdges,exterior_root
    from stock_terrain import StockTerrain,COLLAR
    old=Volume(blob)
    assert old.shape==[2,1,2]
    target=(width,9,width)
    signs=bytearray((total+7)//8)
    chunks=[]
    densities=[]
    materials=[[],[],[],[]]
    old_density=decode_density(old.deltas)
    old_materials=material_parts(old)
    edges=SourceEdges(old,old_density)
    skirt_path=game_dir/'TerrainSkirts'/name/(name+'.bakedHeightMap')
    stock=StockTerrain(skirt_path,edges,size)
    copies=[]
    # Uniform nodes have no explicit samples; sign selects solid / empty.
    uniform=b'\x00\x00'
    for z in range(width):
        for y in range(9):
            for x in range(width):
                index=(z*9+y)*width+x
                progress(5+int(index*70/total), "Preparing terrain: "+str(index+1)+"/"+str(total))
                if y==4 and x in (inner,inner+1) and z in (inner,inner+1):
                    source=(z-inner)*2+(x-inner)
                    tree,_,_,sign=old.roots[source]
                    _,begin,end,_=old.roots[source]
                    density=old_density[begin:end]
                    mat=old_materials[source]
                    copies.append((source,index))
                elif x in (inner,inner+1) and z in (inner,inner+1) and y<4:
                    tree,sign=uniform,0
                    density=b'';mat=(b'',)*4
                elif x in (inner,inner+1) and z in (inner,inner+1) and y>4:
                    tree,sign=uniform,1
                    density=b'';mat=(b'',)*4
                else:
                    tree,density,mat,sign=exterior_root(stock,x,z,y-2)
                signs[index//8] |= sign << (index%8)
                chunks.append(tree)
                densities.append(density)
                for channel,part in zip(materials,mat):channel.append(part)
    tree=b''.join(chunks)
    density=b''.join(densities)
    material_stream=b''.join(b''.join(channel) for channel in materials)
    header=b''.join(put_uint(v) for v in (5,*target,512,1))+b'\x00'
    new_blob=header+signs+put_uint(len(tree))+put_uint(len(density))+tree+encode_density(density)+material_stream
    new=Volume(new_blob)
    assert new.shape==list(target)
    new_density=decode_density(new.deltas)
    new_materials=material_parts(new)
    # Position and byte identity of each complete original 512-metre cube.
    for source,index in copies:
        before,begin,end,sign=old.roots[source]
        after,new_begin,new_end,new_sign=new.roots[index]
        assert before==after and end-begin==new_end-new_begin and sign==new_sign
        assert old_density[begin:end]==new_density[new_begin:new_end]
        assert old_materials[source]==new_materials[index]
        old_pos=((source%2)*512-512,-256,(source//2)*512-512)
        x=index%width;y=(index//width)%9;z=index//(width*9)
        assert old_pos==(x*512-size//2,y*512-2304,z*512-size//2)
    return new_blob,dict(original_geometry_sha256=digest(old.tree),
        original_distance_sha256=digest(old.deltas),original_material_sha256=digest(old.materials),
        preserved_root_count=4,original_sample_count=old.samples,new_sample_count=new.samples,
        added_surface_sample_count=new.samples-old.samples,new_dimensions=[size,4608,size],
        all_original_root_bytes_and_positions_verified=True,original_density_and_material_records_verified=True,
        stock_heightmap_sha256=stock.sha256,stock_material_names=stock.names,
        source_kind='original_baked_heightmap',transition_width=COLLAR,transition_edge_columns_without_crossing=edges.missing_columns,
        source_background_alignment_max_error=stock.edge_alignment_error,
        source_center_height=float(edges.center_height[0]),
        transition_height_profiles=[h.tolist() for h in edges.heights],
        outer_ground_probe_heights={str(x):float(stock.exterior(x,0)[0]) for x in (600,750,900)})


def patch(raw, client_name, replacement):
    size_start,size_end,sizes,blocks=clients(raw)
    index=next(i for i,item in enumerate(blocks) if item[0]==client_name)
    _,start,version_end,end=blocks[index]
    marker=b"\x05\x02\x01\x02\xc2\x00\x01\x00"
    position=raw.index(marker,version_end,end)
    if raw.find(marker,position+1,end)!=-1: raise ValueError('Ambiguous source terrain')
    sizes[index]+=len(replacement)-(end-position)
    result=raw[:size_start]+put_uint(len(sizes))+b''.join(map(put_uint,sizes))+raw[size_end:position]+replacement+raw[end:]
    new_blocks=clients(result)[3]
    for a,b in zip(blocks,new_blocks):
        if a[0]!=client_name and raw[a[1]:a[3]]!=result[b[1]:b[3]]:
            raise ValueError('Non-terrain client changed during generation')
    return result


def source_blob(raw,client):
    record=next(b for b in clients(raw)[3] if b[0]==client)
    marker=b"\x05\x02\x01\x02\xc2\x00\x01\x00"
    start=raw.index(marker,record[2],record[3])
    if raw.find(marker,start+1,record[3])!=-1: raise ValueError('Ambiguous source terrain')
    return raw[start:record[3]]


def request_profile(biome):
    parts=biome.casefold().split(':')
    if len(parts)>2 or parts[0] not in BIOMES: raise ValueError('Unsupported terrain biome')
    size=2048 if len(parts)==1 else int(parts[1])
    if size not in (2048,4096): raise ValueError('Unsupported terrain volume')
    return parts[0],size,'Maps4096' if size==4096 else 'Maps'


def _ensure_maps(mod_dir,biome,progress,game_dir=None):
    mod_dir=Path(mod_dir).resolve()
    biome,size,folder_name=request_profile(biome)
    name=BIOMES.get(biome)
    if not name: raise ValueError('Unsupported terrain biome')
    # Resolve the installation from Win64/ovldata/Mod_BoundaryLab.
    game_dir=Path(game_dir).resolve() if game_dir is not None else mod_dir.parents[2]
    sources=[game_dir/'Parks/Sandbox'/(name+ext) for ext in ('.bin','.trn')]
    sources.append(game_dir/'TerrainSkirts'/name/(name+'.bakedHeightMap'))
    if not all(p.is_file() for p in sources):
        raise ValueError('Original park or landscape files were not found in the game installation')
    inputs={str(p.relative_to(game_dir)).replace('\\','/'):digest(p.read_bytes()) for p in sources}
    folder=mod_dir/folder_name;folder.mkdir(exist_ok=True)
    manifest=folder/(name+'.generation.json')
    outputs=[folder/(name+ext) for ext in ('.bin','.trn')]+[folder/(name+'.checks.lua')]
    try:
        saved=json.loads(manifest.read_text(encoding='utf-8'))
        if (saved['version']==GENERATOR_VERSION and saved.get('size',2048)==size and saved['inputs']==inputs
            and all(p.is_file() and digest(p.read_bytes())==saved['outputs'][p.name] for p in outputs)):
            progress(100,'Terrain ready')
            return {'status':'map_ready','progress':100,'filename':name+'.bin','cached':True,'terrainSize':size}
    except (OSError,ValueError,KeyError,TypeError): pass
    progress(2,'Reading original terrain')
    prefix,raw=unpack(sources[0]);prefix_under,raw_under=unpack(sources[1])
    blob=source_blob(raw,'VoxelTerrain')
    under_blob=source_blob(raw_under,'VoxelTerrainUnderlay')
    if blob!=under_blob: raise ValueError('Original terrain and underlay do not match')
    replacement,report=extend(blob,name,game_dir,progress,size)
    expected=report['outer_ground_probe_heights']
    checks='Heights = {["'+name+'.bin"] = {'+', '.join('['+x+']='+repr(h) for x,h in expected.items())+'}}\n'
    pending=[]
    try:
        for output,preamble,original,client in zip(outputs[:2],(prefix,prefix_under),(raw,raw_under),('VoxelTerrain','VoxelTerrainUnderlay')):
            progress(82 if client=='VoxelTerrain' else 90,'Writing '+output.name)
            result=patch(original,client,replacement)
            data=preamble+zlib.compress(result,level=6,wbits=-15)
            temp=output.with_suffix(output.suffix+'.pending')
            pending.append(temp);temp.write_bytes(data)
            if unpack(temp)!=(preamble,result): raise ValueError('Generated terrain verification failed')
        check_pending=outputs[2].with_suffix('.lua.pending')
        pending.append(check_pending);check_pending.write_text(checks,encoding='utf-8',newline='\n')
        for p in sources:
            if digest(p.read_bytes())!=inputs[p.relative_to(game_dir).as_posix()]:
                raise ValueError('Original game files changed during terrain preparation')
        hashes={p.name:digest(temp.read_bytes()) for temp,p in zip(pending,outputs)}
        # Publish the manifest last. An interrupted pair is never accepted as a cache hit.
        for temp,p in zip(pending,outputs): os.replace(temp,p)
        temp_manifest=manifest.with_suffix('.json.pending')
        temp_manifest.write_text(json.dumps({'version':GENERATOR_VERSION,'size':size,'inputs':inputs,'outputs':hashes,'preservation':report},indent=2),encoding='utf-8')
        os.replace(temp_manifest,manifest)
    finally:
        for temp in pending:
            if temp.exists(): temp.unlink()
    progress(100,'Terrain ready')
    return {'status':'map_ready','progress':100,'filename':name+'.bin','cached':False,'terrainSize':size}


def ensure_maps(mod_dir,biome,progress,game_dir=None):
    from stock_scenery import ensure_scenery
    mod_dir=Path(mod_dir).resolve()
    game_dir=Path(game_dir).resolve() if game_dir is not None else mod_dir.parents[2]
    result=_ensure_maps(mod_dir,biome,lambda n,message: progress(round(n*0.95),message),game_dir)
    biome,size,folder_name=request_profile(biome)
    name=BIOMES[biome]
    progress(96,'Preparing original scenery')
    try:
        result['scenery']=ensure_scenery(mod_dir,name,game_dir,size=size)
    except (OSError,ValueError,AssertionError,struct.error,zlib.error) as error:
        # Optional scenery must never prevent a verified terrain from loading.
        result['scenery_error']=str(error)
        (mod_dir/folder_name/(name+'.decor.lua')).write_text(
            'return {version=1,error="Original scenery could not be prepared. See the scenery error report."}\n',
            encoding='utf-8',newline='\n')
        (mod_dir/folder_name/(name+'.decor-error.txt')).write_text(str(error),encoding='utf-8',newline='\n')
    progress(100,'Terrain ready')
    return result
