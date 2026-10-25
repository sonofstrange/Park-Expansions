import sys,tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parent/'compatibility'))
import auto_convert as worker
with tempfile.TemporaryDirectory(prefix='park-expansions-progress-')as directory:
 records=[]
 def publish(path,**state):records.append(state)
 def maps(mod,biome,progress):
  for percent in (2,30,70,100):progress(percent,'Preparing terrain')
 def prepare(source,mod,progress):
  for percent in (10,50,94):progress(percent,'Converting park')
  return dict(status='ready',progress=100,message='Done')
 args=['worker','--identifier','1733AD85','--name','Test Park','--biome','taiga','--nonce','373-1','--mod-dir',directory]
 with patch.object(sys,'argv',args),patch.object(worker,'write_state',publish),patch.object(worker,'ensure_maps',maps),patch.object(worker,'saved_games',return_value=Path(directory)),patch.object(worker,'find_source',return_value=Path(directory)/'test.park2'),patch.object(worker,'read_archive',return_value=(b'',[(SimpleNamespace(filename='parkdata'),b'fake')])),patch.object(worker,'payload',return_value=b'fake'),patch.object(worker,'clients',return_value=(0,0,[],[])),patch.object(worker,'prepare',prepare):
  assert worker.main()==0
 percentages=[record['progress']for record in records]
 assert percentages==sorted(percentages) and percentages[-1]==100,percentages
 assert any(r['message']=='Preparing terrain'for r in records)
 assert any(r['message']=='Converting park'for r in records)
 print('PASS combined generation/conversion progress is monotonic and uses both real phase callbacks',percentages)
