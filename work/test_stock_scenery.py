"""Compare the small runtime reader with Cobra's independent OVL reader."""
import argparse, hashlib, logging, sys, tempfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent/'compatibility'))
from stock_scenery import placements, ensure_scenery, CLUSTERS
from generate_maps import source_blob
from terrain_codec import unpack,Volume,decode_density
from terrain_transition import SourceEdges
from stock_terrain import StockTerrain

parser=argparse.ArgumentParser()
parser.add_argument('--game-dir',required=True,type=Path)
parser.add_argument('--cobra-tools',required=True,type=Path)
args=parser.parse_args()
sys.path.insert(0,str(args.cobra_tools))
from generated.formats.ovl import OvlFile
logging.disable(logging.CRITICAL);logging.success=logging.info
with tempfile.TemporaryDirectory(prefix='park-expansions-scenery-') as directory:
    mod=Path(directory);(mod/'Maps').mkdir()
    for biome in ('Taiga','Temperate','Tropical','Mediterranean'):
        path=args.game_dir/'Win64/ovldata/Content0/Worlds'/(biome+'World')/(biome+'World.ovl')
        original=hashlib.sha256(path.read_bytes()).hexdigest()
        actual=placements(path)
        ovl=OvlFile();ovl.load(str(path),commands={'game':'Planet Coaster 2'})
        skirt=next(l for l in ovl.loaders.values() if l.ext=='.voxelskirt')
        expected=[]
        for group in skirt.header.entity_groups.data:
            rows=[(i.loc.x,i.loc.y,i.loc.z,i.z_rot) for i in group.entity_instances.data
                  if 512<=max(abs(i.loc.x),abs(i.loc.z))<1020]
            resource=group.name.removesuffix('_SkirtNoShadow').removesuffix('_Skirt')
            if resource in CLUSTERS:resource='PE_'+resource
            if rows:expected.append(dict(resource=resource,prefab=group.name,instances=rows))
        assert actual==expected,biome+' placements differ from original game records'
        baked=args.game_dir/'TerrainSkirts'/(biome+'Sandbox')/(biome+'Sandbox.bakedHeightMap')
        projected=placements(path,baked)
        _,park=unpack(args.game_dir/'Parks/Sandbox'/(biome+'Sandbox.bin'))
        volume=Volume(source_blob(park,'VoxelTerrain'))
        stock=StockTerrain(baked,SourceEdges(volume,decode_density(volume.deltas)))
        for before,after in zip(actual,projected):
            assert before['resource']==after['resource']
            for a,b in zip(before['instances'],after['instances']):
                assert (a[0],a[2],a[3])==(b[0],b[2],b[3])
                ground=float(stock.sample(b[0],b[2])[0])
                assert abs(b[1]-ground)<0.002,(biome,b,ground)
        report=ensure_scenery(mod,biome+'Sandbox',args.game_dir)
        output=mod/'Maps'/(biome+'Sandbox.decor.lua')
        stamp=output.stat().st_mtime_ns
        assert ensure_scenery(mod,biome+'Sandbox',args.game_dir)==report
        assert output.stat().st_mtime_ns==stamp,'Valid scenery cache was rewritten'
        output.write_bytes(b'broken')
        assert ensure_scenery(mod,biome+'Sandbox',args.game_dir)==report
        assert output.read_bytes().startswith(b'return {version=1,source=')
        assert hashlib.sha256(path.read_bytes()).hexdigest()==original,'Original asset changed'
        print('PASS',biome,report['count'],'exact X/Z and yaw, planted on actual Sandbox ground; cache reuse and recovery')
    bad=mod/'bad.ovl';bad.write_bytes(b'not an archive')
    try:placements(bad)
    except ValueError:pass
    else:raise AssertionError('Invalid original archive accepted')
