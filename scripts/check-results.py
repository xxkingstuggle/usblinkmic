#!/usr/bin/env python3
from pathlib import Path
import xml.etree.ElementTree as ET
import re
root=Path(__file__).resolve().parents[1]
reports=list((root/'android/app/build/test-results/testDebugUnitTest').glob('TEST-*.xml'))
assert reports,'no Android unit result XML'
total=0
for path in reports:
 suite=ET.parse(path).getroot()
 assert int(suite.attrib['failures'])==0 and int(suite.attrib['errors'])==0 and int(suite.attrib['skipped'])==0,path.name
 total+=int(suite.attrib['tests'])
assert total>=4,f'Android test baseline regressed: {total}'
print(f'PASS Android unit XML: {total} tests, 0 failures/errors/skips; baseline >=4')
requirements=(root/'docs/requirements.md').read_text()
acceptance=(root/'docs/acceptance.md').read_text()
for n in range(1,25):assert f'T{n:02}' in requirements and f'T{n:02}' in acceptance
assert len(list((root/'macos/CoreTests').glob('*.swift')))>0
print('PASS frozen T01-T24 rows preserved; manual device tests remain pending, not skipped or passed')

swift=(root/'artifacts/swift-latest.log').read_text()
for suite,minimum in [('SupportTests',5),('CoreTests',10),('RenderTests',1),('AudioSessionWatchdogTests',3),('OutputSettingsTests',2)]:
 match=re.search(r"Test Suite '"+suite+r"' passed[^\n]*\n\s*Executed (\d+) tests?, with 0 failures",swift)
 assert match and int(match.group(1))>=minimum, 'Swift baseline regression: '+suite
assert not re.search(r'Test Case .*skipped',swift,re.I)
print('PASS Swift test baseline >=21: Core10/Support5/Render1/Watchdog3/OutputSettings2, 0 failures and skips')
