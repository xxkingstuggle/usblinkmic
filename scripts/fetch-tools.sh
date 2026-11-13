#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tools
python3 - <<'PY'
from pathlib import Path
import hashlib, json, subprocess, zipfile

lock = json.loads(Path('docs/toolchain-lock.json').read_text())['platformTools']
version = lock['version']
archive = Path('.tools') / f'platform-tools_r{version}-darwin.zip'
if not archive.exists():
    partial = archive.with_suffix('.zip.partial')
    subprocess.run(['curl', '--fail', '--location', '--retry', '2',
                    lock['source'], '--output', str(partial)], check=True)
    partial.replace(archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != lock['sha256']:
    raise SystemExit('official tool archive checksum mismatch')

destination = Path('.tools/android-platform')
with zipfile.ZipFile(archive) as bundle:
    bundle.extractall(destination)
(destination / 'platform-tools/adb').chmod(0o755)
print(f'PASS platform-tools {version} pinned archive verified')
PY
