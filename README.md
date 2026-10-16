# USB LinkMic 4

Native macOS26/Apple Silicon + Android8+ companion. Protocol4 remains independent of prior versions. For4.0.3 the user explicitly authorized reading the archived implementation to repair audio/NCM; this repair is not claimed clean-room. NCM shell automation requiresAndroid11+/supported ROM. The user owns functional testing/validation for this build; no acceptance pass is inferred from compilation.

Three uses: phone microphone to Mac (USB/trusted LAN), phone USB CDC-NCM network to Mac on supported ROMs, Mac IPv4 TCP/UDP internet to Android through an explicitly authorized VPN. Includes real PCM metering/output, virtual-input guidance, explicit permission states, settings drafts, and owned-resource cleanup.

## Build and verify

Use Xcode27/Swift6.4, JDK17, Android SDK36/BuildTools35.0.0. Set `JAVA_HOME` to your installed JDK17; set Android SDK with `android/local.properties` (`sdk.dir=...`) or `ANDROID_HOME`. No global installation script or PATH modification is supplied.

```sh
./scripts/validate.sh
./scripts/fetch-tools.sh
./scripts/package.sh 4.0.3-local.1
```

Gradle wrapper8.13 is pinned by SHA256. Build/test caches are project-local. `scripts/package.sh` refuses to overwrite a release directory and uses a local persistent Android signing key excluded from Git. Ordinary runtime users do not need a development environment; APK/ADB/relay/Java are bundled.

The unified command runs Swift tests, Android builds/unit tests/lint/instrumentation compilation, and real local Java relay roundtrip/failure probes. It does not install or request permissions on a phone, replace `/Applications`, or count simulated data as microphone/network acceptance. See [validation](docs/validation.md), [frozen matrix](docs/acceptance.md), [install](docs/install.md), [blockers](BLOCKED.md), and [progress](PROGRESS.md).

## Structure

- `contracts/`, `macos/Contracts`, Android `contracts`: frozen messages/settings/state.
- `macos/Core`, Android `platform`: orchestration, transport, permissions/audio/VPN.
- Native SwiftUI/Compose UI consumes snapshots and emits actions.
- `third_party/gnirehtet`: fresh official Apache-2.0 source; selected forwarding classes integrated separately; original product app is not built.

Logs retain at most500 entries and structured fields are redacted; exports still require user inspection. No cloud accounts or automatic driver install. Exact network/ROM support and hardware performance remain subject to real-device acceptance.
