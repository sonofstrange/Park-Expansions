from pathlib import Path
import xml.etree.ElementTree as ET
import base64
root=Path(__file__).resolve().parents[1]
xml=ET.Element('PPUIPKGRoot',game='Planet Coaster 2')
ET.SubElement(xml,'basic_path').text='Mod_BoundaryLab/Main'
files=ET.SubElement(xml,'files')
for name,target in [('research.js','UIGameface/js/boundarylab/research.js'),('Research.css','UIGameface/css/boundarylab/Research.css')]:
 data=(root/'work/boundarylab/UI'/name).read_bytes()
 entry=ET.SubElement(files,'ppuipkgfile',file_size=str(len(data)))
 ET.SubElement(entry,'file_name').text=target
 ET.SubElement(entry,'file_content',encoding='base64').text=base64.b64encode(data).decode()
ET.SubElement(xml,'icondata');ET.indent(xml)
ET.ElementTree(xml).write(root/'work/boundarylab/Main/boundarylabui.ppuipkg',encoding='utf-8')
