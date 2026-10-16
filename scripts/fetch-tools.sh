#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tools
archive=.tools/platform-tools_r36.0.0-darwin.zip
if [[ ! -f "$archive" ]]; then curl --fail --location --retry 2 https://dl.google.com/android/repository/platform-tools_r36.0.0-darwin.zip --output "$archive"; fi
python3 - <<'PY'
from pathlib import Path
import hashlib,json,zipfile
root=Path('.')
lock=json.loads((root/'docs/toolchain-lock.json').read_text())
archive=root/'.tools/platform-tools_r36.0.0-darwin.zip'
assert hashlib.sha256(archive.read_bytes()).hexdigest()==lock['platformTools']['sha256'],'official tool archive checksum mismatch'
if not (root/'.tools/android-platform/platform-tools/adb').exists():
 with zipfile.ZipFile(archive) as z:z.extractall(root/'.tools/android-platform')
p=root/'.tools/android-platform/platform-tools/adb';p.chmod(0o755)
print('PASS platform-tools36.0.0 pinned archive verified; installed only under project .tools')
PY
