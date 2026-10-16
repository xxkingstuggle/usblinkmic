#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-4.0.0-review.1}"
[[ "$version" =~ ^[0-9A-Za-z.-]+$ ]]
release="$HOME/Developer/releases/usblinkmic/$version"
if [[ -e "$release" ]]; then echo 'Refusing to overwrite an existing release directory' >&2; exit 1; fi
[[ -f android/app/build/outputs/apk/release/app-release-unsigned.apk ]]
[[ -x .tools/android-platform/platform-tools/adb ]]
[[ -f artifacts/relay.jar ]]
swift build -c release
mkdir -p .tools/signing
if [[ ! -f .tools/signing/companion.jks ]]; then
 python3 - <<'PY'
import secrets,os
from pathlib import Path
p=Path('.tools/signing/password');p.write_text(secrets.token_urlsafe(40));os.chmod(p,0o600)
PY
 "$JAVA_HOME/bin/keytool" -genkeypair -keystore .tools/signing/companion.jks -alias companion -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=USBLinkMic Local Build' -storepass:file .tools/signing/password -keypass:file .tools/signing/password
 chmod 600 .tools/signing/companion.jks
fi
if [[ ! -d artifacts/runtime-build/runtime ]]; then
 mkdir -p artifacts/runtime-build
 "$JAVA_HOME/bin/jlink" --add-modules java.base,java.logging,java.naming,jdk.crypto.ec --strip-debug --no-header-files --no-man-pages --output artifacts/runtime-build/runtime
fi
mkdir -p "$release"
tools=$HOME/Library/Android/sdk/build-tools/35.0.0
"$tools/zipalign" -P 16 -f 4 android/app/build/outputs/apk/release/app-release-unsigned.apk "artifacts/aligned-$version.apk"
"$tools/apksigner" sign --ks .tools/signing/companion.jks --ks-key-alias companion --ks-pass file:.tools/signing/password --key-pass file:.tools/signing/password --out "$release/USBLinkMic-$version.apk" "artifacts/aligned-$version.apk"
"$tools/apksigner" verify --verbose --print-certs "$release/USBLinkMic-$version.apk" > "$release/apk-signature.txt"
app="$release/USB LinkMic.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/platform-tools" "$app/Contents/Resources/licenses"
cp .build/release/USBLinkMic "$app/Contents/MacOS/USBLinkMic"
cp "$release/USBLinkMic-$version.apk" "$app/Contents/Resources/companion.apk"
shasum -a 256 "$app/Contents/Resources/companion.apk" | cut -d ' ' -f 1 > "$app/Contents/Resources/companion.sha256"
cp .tools/android-platform/platform-tools/adb "$app/Contents/Resources/platform-tools/adb"
cp .tools/android-platform/platform-tools/NOTICE.txt "$app/Contents/Resources/licenses/Android-platform-tools-NOTICE.txt"
cp .tools/android-platform/platform-tools/source.properties "$app/Contents/Resources/platform-tools/source.properties"
cp third_party/gnirehtet/LICENSE "$app/Contents/Resources/licenses/Gnirehtet-LICENSE.txt"
cp artifacts/relay.jar "$app/Contents/Resources/relay.jar"
ditto artifacts/runtime-build/runtime "$app/Contents/Resources/runtime"
cp docs/dependencies.md "$app/Contents/Resources/licenses/dependencies.md"
python3 - "$app" <<'PY'
from pathlib import Path
import sys,plistlib
app=Path(sys.argv[1])
p={'CFBundleExecutable':'USBLinkMic','CFBundleIdentifier':'com.zjx.usblinkmic.mac','CFBundleName':'USB LinkMic','CFBundleDisplayName':'USB LinkMic','CFBundlePackageType':'APPL','CFBundleShortVersionString':'4.0.0','CFBundleVersion':'40000','LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True,'NSLocalNetworkUsageDescription':'通过你选择的本地地址接收Android手机的Wi-Fi音频。'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(p))
PY
codesign --force --sign - "$app/Contents/Resources/platform-tools/adb"
while IFS= read -r -d '' binary; do
 if file -b "$binary" | /usr/bin/grep -q 'Mach-O'; then codesign --force --sign - "$binary"; fi
done < <(find "$app/Contents/Resources/runtime" -type f -print0)
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app" > "$release/mac-signature.txt" 2>&1
cp docs/install.md "$release/INSTALL.md"
cp docs/acceptance.md "$release/ACCEPTANCE.md"
cp docs/validation.md "$release/VALIDATION.md"
python3 scripts/package-manifest.py "$release"
ditto -c -k --keepParent "$app" "$release/USBLinkMic-$version-macOS.zip"
mkdir -p "artifacts/dmg-$version"
ditto "$app" "artifacts/dmg-$version/USB LinkMic.app"
hdiutil create -volname 'USB LinkMic 4 Review' -srcfolder "artifacts/dmg-$version" -format UDZO "$release/USBLinkMic-$version.dmg"
hdiutil verify "$release/USBLinkMic-$version.dmg"
python3 - "$release" <<'PY'
import hashlib,sys
from pathlib import Path
root=Path(sys.argv[1]);files=sorted(p for p in root.iterdir() if p.is_file() and p.name!='SHA256SUMS.txt')
(root/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in files))
PY
printf 'Release prepared: %s\n' "$release"
