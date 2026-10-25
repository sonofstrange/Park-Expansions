from pathlib import Path
import logging
import subprocess
import sys
import shutil
import os

root = Path(__file__).resolve().parent
cobra = Path(os.environ.get('COBRA_TOOLS', root / 'cobra-tools')).resolve()
sys.path.insert(0, str(cobra))
from generated.formats.ovl import OvlFile
from generated.formats.ovl_base.enums.Compression import Compression
from modules.formats.utils import lua_conversion

logging.disable(logging.CRITICAL)
logging.success = logging.info
luac = cobra / 'modules/formats/utils/luadec/luac.exe'
def syntax_check(path):
    subprocess.run([str(luac), '-p', str(path)], check=True)
lua_conversion.check_lua_syntax = syntax_check
src = root / 'boundarylab/Main'
for p in src.glob('*.lua'):
    syntax_check(p)
out = root / 'boundarylab/Mod_BoundaryLab'
out.mkdir(parents=True, exist_ok=True)
ovl = OvlFile()
ovl.game = 'Planet Coaster 2'
ovl.load_hash_table()
ovl.user_version.compression = Compression.ZLIB
ovl.create(str(src))
ovl.save(str(out / 'Main.ovl'))
check = OvlFile()
check.load(str(out / 'Main.ovl'), commands={'game': 'Planet Coaster 2'})
assert len(check.loaders) == 3
for source in src.glob('*.lua'):
    loader = check.loaders[source.name]
    assert loader.data_entry.buffer_datas[0] == source.read_bytes()
ui=check.loaders['boundarylabui.ppuipkg'].header
assert int(ui.files_count)==2
for entry in ui.files.data:
    raw=bytes(entry.file_content.data)
    assert raw in ((root/'boundarylab/UI/research.js').read_bytes(),(root/'boundarylab/UI/Research.css').read_bytes())
shutil.copy2(root / 'boundarylab/Config.ini', out / 'Config.ini')
(out / 'Manifest.xml').write_text('''<ContentPack version="1">
  <Name>Mod_BoundaryLab</Name>
  <ID>fb3d2950-d08a-4f88-ad50-a8d0f05c5347</ID>
  <Version>1</Version>
  <Type>Game</Type>
</ContentPack>
''', encoding='utf-8')
print('Built', out)
