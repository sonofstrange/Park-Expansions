"""Convert supported LOCAL old parks into separate Park Expansions copies.
Uses only the Python standard library. Never overwrites the input or output.
"""
from pathlib import Path
import argparse,copy,io,json,math,struct,uuid,zipfile,zlib
from terrain_codec import Volume,unpack,clients,put_uint,digest,decode_density,encode_density,material_parts
BIOMES={'temperate':'TemperateSandbox.bin','tropical':'TropicalSandbox.bin','taiga':'TaigaSandbox.bin','mediterranean':'MediterraneanSandbox.bin'}

def read_archive(path):
    original=path.read_bytes();fixed=bytearray(original)
    end=fixed.rfind(b'PK\x05\x06')
    if end<0:raise ValueError('Not a supported local save archive')
    central_size,central=struct.unpack_from('<II',fixed,end+12)
    if central_size==0:
        if not (0<=central<end and fixed[central:central+4]==b'PK\x01\x02'):raise ValueError('Invalid save directory')
        struct.pack_into('<I',fixed,end+12,end-central)
    with zipfile.ZipFile(io.BytesIO(fixed))as z:
        records=[(copy.copy(info),z.read(info))for info in z.infolist()]
    if len({x.filename for x,_ in records})!=len(records):raise ValueError('Duplicate save archive entries')
    if not {'metadata','parkdata'}.issubset({x.filename for x,_ in records}):raise ValueError('Missing native park data')
    return original,records

def payload(data):
    if data[:4]!=b'\xff\x00\xfe\x01' or len(data)<16:raise ValueError('Unknown native data envelope')
    if struct.unpack_from('>I',data,12)[0]!=len(data)-16:raise ValueError('Native payload length mismatch')
    body=data[16:]
    if struct.unpack_from('>I',data,4)[0]!=native_crc(body):raise ValueError('Native payload checksum mismatch')
    return body

def native_crc(data):
    # Native save envelopes use reflected CRC32 with initial zero and no final XOR.
    return zlib.crc32(data,0xffffffff)^0xffffffff

def wrap(original,data):
    return original[:4]+struct.pack('>I',native_crc(data))+original[8:12]+struct.pack('>I',len(data))+data

def scalar(data,p):
    tag=data[p];p+=1
    if tag<0x40:return tag,p
    if tag<0x80:return -(tag&0x3f),p
    if tag<0xc0:
        high=((tag&0x1f)+0x30)|((tag&0x20)<<2)
        return struct.unpack('>f',bytes([high])+data[p:p+3])[0],p+3
    if tag<0xf0:
        n=(tag>>4)-11;value=((tag&7)<<(8*n))|int.from_bytes(data[p:p+n],'big')
        return (-value if tag&8 else value),p+n
    if tag==0xf0:return int.from_bytes(data[p:p+4],'big'),p+4
    raise ValueError('Unsupported numeric boundary record')

def boundary(raw,blocks):
    block=next(b for b in blocks if b[0]=='Boundary');p=block[1]
    version,p=scalar(raw,p);zero,p=scalar(raw,p);count,p=scalar(raw,p)
    if version!=4 or zero!=0 or not isinstance(count,int) or not 4<=count<=100000:raise ValueError('Unsupported boundary version')
    posts=[]
    for _ in range(count):
        fields=[]
        for _ in range(10):value,p=scalar(raw,p);fields.append(value)
        if fields[8]==40:posts.append(fields)
    if len(posts)<4:raise ValueError('No supported park boundary found')
    if not all(math.isfinite(v)for row in posts for v in row[1:4]):raise ValueError('Invalid boundary positions')
    bounds=[min(x[1]for x in posts),max(x[1]for x in posts),min(x[3]for x in posts),max(x[3]for x in posts)]
    if not all(-512<=n<=512 for n in bounds):raise ValueError('Boundary is outside standard source terrain')
    return posts[0][1:4],bounds,len(posts)

def merge_volume(old_blob,donor_blob,progress=None):
    old,donor=Volume(old_blob),Volume(donor_blob)
    if old.shape!=[2,1,2] or donor.shape!=[4,9,4]:raise ValueError('Supported conversion: original 1024 x 512 x 1024 terrain only')
    old_d,donor_d=decode_density(old.deltas),decode_density(donor.deltas)
    old_m,donor_m=material_parts(old),material_parts(donor)
    signs=bytearray(18);trees=[];densities=[];materials=[[],[],[],[]];mapping=[]
    for z in range(4):
        for y in range(9):
            for x in range(4):
                index=(z*9+y)*4+x
                if x in (1,2)and y==4 and z in (1,2):
                    source=(z-1)*2+x-1;tree,a,b,sign=old.roots[source]
                    d,m=old_d[a:b],old_m[source];mapping.append((source,index))
                else:
                    tree,a,b,sign=donor.roots[index];d,m=donor_d[a:b],donor_m[index]
                signs[index//8]|=sign<<(index%8);trees.append(tree);densities.append(d)
                for plane,part in zip(materials,m):plane.append(part)
        if progress: progress(30+int(40*(z+1)/4),'Preserving existing terrain and adding outer ground')
    tree=b''.join(trees);density=b''.join(densities)
    result=b''.join(put_uint(v)for v in (5,4,9,4,512,1))+b'\0'+signs+put_uint(len(tree))+put_uint(len(density))+tree+encode_density(density)+b''.join(b''.join(plane)for plane in materials)
    new=Volume(result);new_d=decode_density(new.deltas);new_m=material_parts(new)
    copied={b:a for a,b in mapping}
    for index,(tree,a,b,sign)in enumerate(new.roots):
        source=copied.get(index)
        original=old if source is not None else donor;original_index=source if source is not None else index
        expected_tree,c,d,expected_sign=original.roots[original_index]
        expected_d=old_d if source is not None else donor_d;expected_m=old_m if source is not None else donor_m
        assert tree==expected_tree and sign==expected_sign and new_d[a:b]==expected_d[c:d] and new_m[index]==expected_m[original_index]
    for source,index in mapping:
        assert (source%2*512-512,-256,source//2*512-512)==(index%4*512-1024,(index//4)%9*512-2304,index//36*512-1024)
    return result,{'original_roots_preserved':len(mapping),'donor_roots_preserved':140,'world_coordinates_verified':True,'distance_and_material_records_verified':True}

def convert(source,mod_dir,output=None,progress=None):
    source=source.resolve();mod_dir=mod_dir.resolve()
    if output is not None:
        output=output.resolve()
        if output==source or output.exists():raise ValueError('Output must be a new file; overwriting is not supported')
    original,records=read_archive(source);data={info.filename:raw for info,raw in records}
    metadata=json.loads(payload(data['metadata']).decode('utf-8'));save=metadata.get('tSave',{})
    if save.get('parkExpansions'):raise ValueError('This park has already been converted')
    if str(save.get('sGameMode','')).lower()not in ('sandbox','challenge'):raise ValueError('Only local Sandbox and Challenge parks are supported')
    filename=BIOMES.get(str(save.get('sGeome','')).lower())
    if not filename:raise ValueError('Unsupported biome')
    raw=data['parkdata'];payload(raw)
    start,end,sizes,blocks=clients(raw)
    if any(b[0]=='BoundaryLabResearch'for b in blocks):raise ValueError('Save already contains Park Expansions research data')
    seed,bounds,posts=boundary(raw,blocks)
    if progress: progress(20,'Checking terrain storage and park boundaries')
    index=next(i for i,b in enumerate(blocks)if b[0]=='VoxelTerrain');block=blocks[index]
    marker=b'\x05\x02\x01\x02\xc2\x00\x01\x00'
    pos=raw.index(marker,block[2],block[3]);old_blob=raw[pos:block[3]]
    _,donor_raw=unpack(mod_dir/'Maps'/filename);donor_block=next(b for b in clients(donor_raw)[3]if b[0]=='VoxelTerrain')
    donor_pos=donor_raw.index(b'\x05\x04\x09\x04\xc2\x00\x01\x00',donor_block[2],donor_block[3])
    new_blob,report=merge_volume(old_blob,donor_raw[donor_pos:donor_block[3]],progress)
    if progress: progress(80,'Verifying all preserved park objects and terrain')
    sizes[index]+=len(new_blob)-len(old_blob)
    changed=raw[:start]+put_uint(len(sizes))+b''.join(map(put_uint,sizes))+raw[end:pos]+new_blob+raw[block[3]:]
    changed=wrap(raw,changed[16:])
    new_blocks=clients(changed)[3];unchanged=[]
    for before,after in zip(blocks,new_blocks):
        assert before[0]==after[0]
        if before[0]!='VoxelTerrain':
            assert raw[before[1]:before[3]]==changed[after[1]:after[3]];unchanged.append(before[0])
    assert raw[16:start]==changed[16:start]
    source_hash=digest(original)
    name=metadata.get('sName')or save.get('sParkName')or source.stem
    new_name=name+' - Park Expansions'
    metadata['sName']=new_name;save['sParkName']=new_name
    save['parkExpansions']={'version':1,'filename':filename,'seed':seed,'bounds':bounds,'sourceHash':source_hash,'sourceName':name}
    metadata['bIsModded']=True
    metadata_bytes=wrap(data['metadata'],json.dumps(metadata,ensure_ascii=False,separators=(',',':')).encode('utf-8'))
    output=(output or source.parent/(new_name+'-'+uuid.uuid4().hex[:8].upper()+'.park2')).resolve()
    if output==source or output.exists():raise ValueError('Output must be a new file; overwriting is not supported')
    output.parent.mkdir(parents=True,exist_ok=True)
    archive=io.BytesIO()
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6)as z:
        for info,entry in records:z.writestr(info,changed if info.filename=='parkdata'else metadata_bytes if info.filename=='metadata'else entry)
    result=bytearray(archive.getvalue());directory=result.rfind(b'PK\5\6')
    # Match the game's directory convention (entry count/offset present, size zero).
    struct.pack_into('<I',result,directory+12,0)
    with output.open('xb')as f:f.write(result)
    try:
        _,verified_records=read_archive(output);verified={info.filename:entry for info,entry in verified_records}
        assert verified['parkdata']==changed and verified['metadata']==metadata_bytes
        payload(verified['parkdata']);payload(verified['metadata'])
        assert all(verified[k]==v for k,v in data.items()if k not in ('metadata','parkdata'))
        assert digest(source.read_bytes())==source_hash
    except BaseException:
        # Keep a failed output for diagnosis; never modify or remove the original.
        raise
    report.update(source=str(source),output=str(output),source_sha256=source_hash,output_sha256=digest(result),biome=save['sGeome'],boundary_posts=posts,original_clients_unchanged=unchanged,all_other_archive_entries_unchanged=True)
    if progress: progress(92,'Verified the converted copy; original save unchanged')
    output.with_suffix('.conversion.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    return output,report

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('source',type=Path);parser.add_argument('--mod-dir',type=Path,default=Path(__file__).resolve().parent.parent);parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    try:
        path,report=convert(args.source,args.mod_dir,args.output)
        print('Created:',path);print('Original save unchanged. Load the copy with Park Expansions 0.31 or later.')
    except Exception as error:parser.exit(1,'Conversion failed: '+str(error)+'\n')
