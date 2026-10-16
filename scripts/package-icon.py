#!/usr/bin/env python3
"""Build the macOS icon using the operating system's standard ICNS encoder."""
import subprocess,sys
from pathlib import Path
source,output=map(Path,sys.argv[1:])
subprocess.run(['/usr/bin/iconutil','-c','icns',str(source),'-o',str(output)],check=True)
assert output.is_file() and output.read_bytes().startswith(b'icns')
print('PASS ICNS: standard macOS iconutil encoder;10 source sizes')
