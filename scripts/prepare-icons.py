#!/usr/bin/env python3
"""Derive platform icon sizes from the user-supplied image using macOS sips."""
from pathlib import Path
import hashlib,json,subprocess
root=Path(__file__).resolve().parents[1]
source=root/'assets/branding/app-icon-source.png'
outputs=[]
def resize(relative,size):
 path=root/relative;path.parent.mkdir(parents=True,exist_ok=True)
 subprocess.run(['/usr/bin/sips','-z',str(size),str(size),str(source),'--out',str(path)],check=True,stdout=subprocess.DEVNULL)
 outputs.append({'path':relative,'pixels':size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
for name,size in {'icon_16x16.png':16,'icon_16x16@2x.png':32,'icon_32x32.png':32,'icon_32x32@2x.png':64,'icon_128x128.png':128,'icon_128x128@2x.png':256,'icon_256x256.png':256,'icon_256x256@2x.png':512,'icon_512x512.png':512,'icon_512x512@2x.png':1024}.items():
 resize('macos/Resources/AppIcon.iconset/'+name,size)
for density,size in {'mdpi':48,'hdpi':72,'xhdpi':96,'xxhdpi':144,'xxxhdpi':192}.items():
 for name in ['ic_launcher','ic_launcher_round']:resize('android/app/src/main/res/mipmap-'+density+'/'+name+'.png',size)
resize('android/app/src/main/res/drawable/ic_launcher_full.png',432)
(root/'docs/icon-provenance.json').write_text(json.dumps({'authorization':'User supplied replacement artwork on2026-10-17 for both platforms; supersedes legacy icon retention.','source':'assets/branding/app-icon-source.png','sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'conversion':'macOS sips proportional square resizing; full original image retained; no redraw, cropping or color change. Android adaptive foreground adds12dp safe padding.','assets':outputs},ensure_ascii=False,indent=2)+'\n')
print('Derived',len(outputs),'platform PNGs; provenance recorded')
