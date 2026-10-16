#!/usr/bin/env python3
"""Store the original PNG payloads in an ICNS container without resampling."""
import struct
import sys
from pathlib import Path

source, output = map(Path, sys.argv[1:])
types = {
    'icon_16x16.png': b'icp4', 'icon_16x16@2x.png': b'ic11',
    'icon_32x32.png': b'icp5', 'icon_32x32@2x.png': b'ic12',
    'icon_128x128.png': b'ic07', 'icon_128x128@2x.png': b'ic13',
    'icon_256x256.png': b'ic08', 'icon_256x256@2x.png': b'ic14',
    'icon_512x512.png': b'ic09', 'icon_512x512@2x.png': b'ic10',
}
chunks = []
for name, kind in types.items():
    data = (source / name).read_bytes()
    assert data.startswith(b'\x89PNG\r\n\x1a\n'), name
    chunks.append(kind + struct.pack('>I', len(data) + 8) + data)
payload = b''.join(chunks)
output.write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
print('PASS ICNS: all10 original PNG payloads preserved without conversion')
