#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,sys,platform,subprocess
root=Path(sys.argv[1]);resources=root/'USB LinkMic.app/Contents/Resources'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
items=[]
for p in sorted(resources.rglob('*')):
 if p.is_file() and not p.is_symlink():items.append({'path':str(p.relative_to(root)),'sha256':sha(p),'bytes':p.stat().st_size})
manifest={'version':'4.0.0','protocol':4,'status':'review-build-pending-device-and-install-acceptance','platform':{'macOS':'26+ Apple Silicon','Android':'8+ API26'},'signing':'Mac ad-hoc (not notarized); Android local persistent build key, certificate in apk-signature.txt','sourceCommit':subprocess.run(['git','rev-parse','HEAD'],text=True,capture_output=True).stdout.strip() or 'precommit','requirementsSHA256':'a26707d007f8c3d88b368d34c15358380f2f68386130885eacaccd1553dc0976','resources':items,'excluded':'tests, fixtures, debug APK, signing secrets, development tools not required at runtime'}
(root/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
assert not any('fixtures' in item['path'] or 'test' in item['path'].lower() for item in items)
assert sha(resources/'companion.apk')==(resources/'companion.sha256').read_text().strip()
print('PASS package manifest: bundled APK fingerprint and resource hashes recorded; no test fixtures')
