#!/usr/bin/env python3
"""Bounded source precommit scan. Detect common credential/key forms; no secret values printed."""
from pathlib import Path
import re,sys
root=Path(__file__).resolve().parents[1]
exclude={'.git','.tools','.cache','.build','artifacts','build','.gradle','.android','third_party'}
patterns=[re.compile(p) for p in [r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',r'gh[pousr]_[A-Za-z0-9]{30,}',r'github_pat_[A-Za-z0-9_]{30,}',r'AKIA[0-9A-Z]{16}',r'sk-[A-Za-z0-9]{32,}']]
issues=[];count=0
for path in root.rglob('*'):
 if not path.is_file() or any(p in exclude for p in path.relative_to(root).parts):continue
 if path.suffix.lower() in {'.jks','.keystore','.pem'} or path.name=='.env':issues.append(str(path.relative_to(root)));continue
 if path.stat().st_size>2_000_000:continue
 try:text=path.read_text()
 except (UnicodeError,OSError):continue
 count+=1
 if any(p.search(text) for p in patterns):issues.append(str(path.relative_to(root)))
if issues:
 print('FAIL secret-risk files:',', '.join(issues));sys.exit(1)
print(f'PASS bounded secret scan: {count} text files; private build/cache/third-party excluded (third-party official sources only)')
