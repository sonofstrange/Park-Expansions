"""Background component of Park Expansions. Started by the in-game Lua bridge."""
from pathlib import Path
import argparse, ctypes, hashlib, json, os, re, struct, sys, traceback, zlib
from convert_park import convert, read_archive, payload, BIOMES
from terrain_codec import clients, unpack
from generate_maps import ensure_maps


def lua(value):
    if value is None: return 'nil'
    if isinstance(value, bool): return 'true' if value else 'false'
    if isinstance(value, (float, int)): return repr(value)
    if isinstance(value, str):
        return '"'+''.join(chr(b) if 32 <= b < 127 and b not in (34,92) else '\\%03d'%b for b in value.encode('utf-8'))+'"'
    if isinstance(value, list): return '{'+','.join(map(lua,value))+'}'
    return '{'+','.join('['+lua(k)+']='+lua(v) for k,v in value.items())+'}'


_progress_sequences={}


def write_state(path, **state):
    # The game's VFS can open a Lua file without FILE_SHARE_DELETE. Never
    # replace a file that the game might be reading: publish each update once.
    nonce=path.stem.removeprefix('State-')
    if state.get('status')=='working':
        sequence=_progress_sequences.get(path,0)+1
        _progress_sequences[path]=sequence
        path=path.with_name('Progress-'+nonce+'-'+str(sequence)+'.lua')
    else:
        path=path.with_name('Result-'+nonce+'.lua')
    temp=path.with_suffix('.tmp')
    temp.write_text('return '+lua(state)+'\n',encoding='utf-8',newline='\n')
    os.rename(temp,path)


def saved_games():
    # Respect Windows Known Folder redirection instead of assuming USERPROFILE.
    class GUID(ctypes.Structure):
        _fields_=[('Data1',ctypes.c_uint32),('Data2',ctypes.c_uint16),('Data3',ctypes.c_uint16),('Data4',ctypes.c_ubyte*8)]
    import uuid
    guid=GUID.from_buffer_copy(uuid.UUID('4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4').bytes_le)
    ptr=ctypes.c_wchar_p()
    get_folder=ctypes.windll.shell32.SHGetKnownFolderPath
    get_folder.argtypes=[ctypes.POINTER(GUID),ctypes.c_uint32,ctypes.c_void_p,ctypes.POINTER(ctypes.c_wchar_p)]
    get_folder.restype=ctypes.c_long
    result=get_folder(ctypes.byref(guid),0,None,ctypes.byref(ptr))
    if result: raise OSError('Windows Saved Games folder is unavailable')
    try: return Path(ptr.value)/'Frontier Developments/Planet Coaster 2'
    finally: ctypes.windll.ole32.CoTaskMemFree(ptr)


def find_source(root, identifier, name, biome):
    if not root.is_dir(): raise ValueError('Planet Coaster 2 save folder was not found')
    candidates=[]
    for folder in sorted(root.iterdir()):
        if not folder.is_dir() or not folder.name.isdecimal(): continue
        saves=folder/'Saves'
        if not saves.is_dir(): continue
        for path in saves.glob('*.park2'):
            if path.stat().st_size==0: continue
            # Identifiers differ between native stores: accept a full basename,
            # the native hexadecimal suffix, or a unique exact metadata name.
            stem=path.stem.casefold();ident=identifier.casefold()
            strong=ident in (stem,path.name.casefold(),stem.rsplit('-',1)[-1])
            if not strong and not stem.startswith(name.casefold()+'-'): continue
            try:
                _,records=read_archive(path)
                metadata=json.loads(payload(next(d for i,d in records if i.filename=='metadata')))
                save=metadata.get('tSave',{})
                if save.get('parkExpansions'): continue
                if save.get('sGeome','').casefold()!=biome.casefold(): continue
                names=(metadata.get('sName'),save.get('sParkName'))
                if not strong and name not in names: continue
                candidates.append((strong,path))
            except (ValueError,StopIteration,OSError,KeyError):
                if strong: raise
    strongest=[p for strong,p in candidates if strong]
    chosen=strongest or [p for _,p in candidates]
    if len(chosen)!=1: raise ValueError('Could not identify one local save safely; original park will load unchanged')
    return chosen[0]


def prepare(source, mod_dir, progress):
    source=source.resolve();cache=mod_dir/'AutoConversion'
    cache.mkdir(exist_ok=True)
    fingerprint=hashlib.sha256(source.read_bytes()).hexdigest()
    target=cache/(fingerprint+'.park2');native=cache/(fingerprint+'.bin')
    progress(10,'Checking the selected save')
    if target.exists():
        _,records=read_archive(target)
        data={i.filename:d for i,d in records}
        info=json.loads(payload(data['metadata']))['tSave']['parkExpansions']
        if info.get('sourceHash')!=fingerprint: raise ValueError('Cached conversion does not match the original save')
        payload(data['parkdata'])
    else:
        # Commit the cache only after the converter's full preservation checks.
        pending=cache/(fingerprint+'.pending.park2')
        if pending.exists(): pending.unlink()
        convert(source,mod_dir,pending,progress=progress)
        os.replace(pending,target)
        report=pending.with_suffix('.conversion.json')
        os.replace(report,target.with_suffix('.conversion.json'))
        _,records=read_archive(target);data={i.filename:d for i,d in records}
        info=json.loads(payload(data['metadata']))['tSave']['parkExpansions']
    progress(94,'Preparing the converted world for loading')
    raw=payload(data['parkdata'])
    compressor=zlib.compressobj(6,zlib.DEFLATED,-15)
    encoded=b'[PlCo2WoSa][COMP]'+compressor.compress(raw)+compressor.flush()
    pending=native.with_suffix('.pending.bin');pending.write_bytes(encoded)
    _,verified=unpack(pending)
    if verified!=raw: raise ValueError('Converted world verification failed')
    clients(verified)
    if hashlib.sha256(source.read_bytes()).hexdigest()!=fingerprint:
        raise ValueError('Original save changed during conversion; loading it unchanged')
    os.replace(pending,native)
    return dict(status='ready',progress=100,message='Conversion verified. Loading the expanded copy.',
                native='/run/Win64/ovldata/Mod_BoundaryLab/AutoConversion/'+native.name,
                info=info,source=str(source),sourceHash=fingerprint)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identifier',required=True);parser.add_argument('--name',required=True)
    parser.add_argument('--biome',required=True);parser.add_argument('--nonce',required=True)
    parser.add_argument('--mod-dir',required=True,type=Path)
    args=parser.parse_args()
    if not re.fullmatch(r'[0-9]+-[0-9]+',args.nonce): raise ValueError('Invalid conversion request')
    mod=args.mod_dir.resolve();cache=mod/'AutoConversion';cache.mkdir(exist_ok=True)
    state=cache/('State-'+args.nonce+'.lua')
    def progress(percent,message): write_state(state,status='working',progress=percent,message=message)
    try:
        if args.identifier=='__prepare_map__':
            write_state(state,**ensure_maps(mod,args.biome,progress))
            return 0
        progress(1,'Finding the selected local save')
        if args.biome.casefold() not in BIOMES: raise ValueError('Unsupported park biome')
        # Lua prepares the map before conversion. Validate the same cache here.
        ensure_maps(mod,args.biome,lambda percent,message: None)
        source=find_source(saved_games(),args.identifier,args.name,args.biome)
        _,original_records=read_archive(source)
        original_data=next(d for i,d in original_records if i.filename=='parkdata')
        payload(original_data)
        if any(b[0]=='BoundaryLabResearch' for b in clients(original_data)[3]):
            write_state(state,status='skip',progress=0,message='Existing Park Expansions world data retained.')
            return 0
        write_state(state,**prepare(source,mod,progress))
    except Exception as error:
        message=str(error)
        if isinstance(error,OSError):
            message='Automatic conversion could not access a required file (Windows error '+str(getattr(error,'winerror',error.errno))+'). Original park unchanged. See the conversion error report.'
        elif not isinstance(error,ValueError):
            message='Automatic conversion failed. Original park unchanged. See the conversion error report.'
        write_state(state,status='error',progress=0,message=message)
        (cache/('Error-'+args.nonce+'.txt')).write_text(traceback.format_exc(),encoding='utf-8')
        return 1
    return 0


if __name__=='__main__': sys.exit(main())
