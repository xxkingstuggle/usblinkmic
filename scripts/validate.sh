#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export GRADLE_USER_HOME="$PWD/.cache/gradle"
export ANDROID_USER_HOME="$PWD/android/.android"
mkdir -p artifacts docs/evidence
shasum -a 256 -c docs/requirements.sha256
python3 scripts/secret-scan.py
swift test 2>&1 | tee artifacts/swift-latest.log
./android/gradlew -p android :app:assembleDebug :app:assembleRelease :app:testDebugUnitTest :app:lintDebug :app:compileDebugAndroidTestKotlin --console=plain
mkdir -p artifacts/relay-classes
find third_party/gnirehtet/relay-java/src/main/java -name '*.java' -print > artifacts/relay-sources.txt
"${JAVA_HOME:?JDK17 JAVA_HOME required}/bin/javac" -d artifacts/relay-classes @artifacts/relay-sources.txt
"$JAVA_HOME/bin/jar" --create --file artifacts/relay.jar --main-class com.genymobile.gnirehtet.Main -C artifacts/relay-classes .
python3 scripts/relay-integration.py
python3 scripts/check-results.py
