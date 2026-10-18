#!/usr/bin/env python3
"""Derive platform icon sizes from the user-supplied image using macOS sips."""
from pathlib import Path
import argparse,hashlib,json,subprocess
parser=argparse.ArgumentParser()
parser.add_argument('--mac-only',action='store_true',help='Regenerate Mac resources without touching Android artwork')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
source=root/'assets/branding/app-icon-source.png'
mac_source=root/'assets/branding/mac-app-icon-prepared.png'
outputs=[]
def resize(relative,size,input_source=source):
 path=root/relative;path.parent.mkdir(parents=True,exist_ok=True)
 subprocess.run(['/usr/bin/sips','-z',str(size),str(size),str(input_source),'--out',str(path)],check=True,stdout=subprocess.DEVNULL)
 outputs.append({'path':relative,'pixels':size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
for name,size in {'icon_16x16.png':16,'icon_16x16@2x.png':32,'icon_32x32.png':32,'icon_32x32@2x.png':64,'icon_128x128.png':128,'icon_128x128@2x.png':256,'icon_256x256.png':256,'icon_256x256@2x.png':512,'icon_512x512.png':512,'icon_512x512@2x.png':1024}.items():
 resize('macos/Resources/AppIcon.iconset/'+name,size,mac_source)
if not args.mac_only:
 for density,size in {'mdpi':48,'hdpi':72,'xhdpi':96,'xxhdpi':144,'xxxhdpi':192}.items():
  for name in ['ic_launcher','ic_launcher_round']:resize('android/app/src/main/res/mipmap-'+density+'/'+name+'.png',size)
 resize('android/app/src/main/res/drawable/ic_launcher_full.png',432)
else:
 outputs.extend(item for item in json.loads((root/'docs/icon-provenance.json').read_text())['assets'] if item['path'].startswith('android/'))
(root/'docs/icon-provenance.json').write_text(json.dumps({'authorization':'User supplied artwork on 2026-10-17; authorized Mac icon repair on 2026-10-18. Android artwork retained.','source':'assets/branding/app-icon-source.png','sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'conversion':'Mac: AI-redrawn full-bleed square master; a single native rounded tile mask on an824px tile with100px transparent margins; system sips sizes and iconutil ICNS. Android retains the original image with12dp adaptive padding.','macEditedSource':'assets/branding/mac-app-icon.png','macEditedSHA256':hashlib.sha256((root/'assets/branding/mac-app-icon.png').read_bytes()).hexdigest(),'macProcessingScript':'scripts/prepare-mac-icon.swift','macPreparedSource':str(mac_source.relative_to(root)),'macPreparedSHA256':hashlib.sha256(mac_source.read_bytes()).hexdigest(),'assets':outputs},ensure_ascii=False,indent=2)+'\n')
print('Derived',len(outputs),'platform PNGs; provenance recorded')
