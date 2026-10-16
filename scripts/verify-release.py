#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,sys,zipfile
root=Path(sys.argv[1]);manifest=json.loads((root/'manifest.json').read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
assert manifest['protocol']==4
assert manifest['requirementsSHA256']=='a26707d007f8c3d88b368d34c15358380f2f68386130885eacaccd1553dc0976'
for item in manifest['resources']:
 p=root/item['path'];assert p.is_file() and p.stat().st_size==item['bytes'] and sha(p)==item['sha256'],item['path']
for line in (root/'SHA256SUMS.txt').read_text().splitlines():
 expected,name=line.split('  ',1);assert sha(root/name)==expected,name
apk=next(root.glob('USBLinkMic-*.apk'))
resources=root/'USB LinkMic.app/Contents/Resources'
assert sha(apk)==sha(resources/'companion.apk')==(resources/'companion.sha256').read_text().strip()
with zipfile.ZipFile(next(root.glob('*macOS.zip'))) as z:
 names=z.namelist();assert 'USB LinkMic.app/Contents/MacOS/USBLinkMic' in names
 assert not any('/fixtures/' in n or '/Tests/' in n or '.jks' in n or '/signing/' in n for n in names)
 assert hashlib.sha256(z.read('USB LinkMic.app/Contents/Resources/companion.apk')).hexdigest()==sha(apk)
print(f'PASS final package: {len(manifest["resources"])} resource hashes, all checksum entries, bundled/external APK identity, ZIP structure and fixture/key exclusion')
