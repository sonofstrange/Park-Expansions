"""Integration check against locally installed stock game assets; no saves required."""
import argparse,sys,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent/'compatibility'))
from generate_maps import ensure_maps,BIOMES

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--game-dir',required=True,type=Path)
 parser.add_argument('--biome',choices=list(BIOMES),default='taiga');args=parser.parse_args()
 root=Path(__file__).resolve().parents[1];stage=root/'build/generation-test/Mod_BoundaryLab';stage.mkdir(parents=True,exist_ok=True)
 last=[-1];started=time.monotonic()
 def progress(n,message):
  if n//10!=last[0]:print(n,message,round(time.monotonic()-started,1),flush=True);last[0]=n//10
 result=ensure_maps(stage,args.biome,progress,game_dir=args.game_dir)
 print('GENERATION',result,flush=True)
 name=BIOMES[args.biome]
 for ext in ('.bin','.trn'):
  path=stage/'Maps'/(name+ext)
  reference=root/'work/boundarylab/Mod_BoundaryLab/Maps'/(name+ext)
  assert path.read_bytes()==reference.read_bytes(),str(path)+' differs from the verified release'
 cached=ensure_maps(stage,args.biome,lambda *_:None,game_dir=args.game_dir)
 assert cached['cached'] is True
 print('PASS exact release bytes, preserved roots and reusable verified cache',flush=True)
if __name__=='__main__':main()
