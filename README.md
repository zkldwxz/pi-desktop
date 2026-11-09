# pi-desktop

[简体中文](README_CN.md) · [日本語](README_JA.md) · [Français](README_FR.md) · [Español](README_ES.md)

pi-desktop is a Flutter desktop workspace using the [Pi coding agent](https://github.com/earendil-works/pi). It is an independent fork of [BaoCode](https://github.com/baocode-dev/baocode), retaining its GPL license and upstream notices.

The fork uses Pi's JSONL RPC and native provider protocols for supported standard APIs, avoiding an extra protocol translation layer. It preserves context within a session and tracks cache-read and cache-write usage per request when reported by the provider. Stable prompts and session context may improve cache reuse, but no higher hit rate has been measured: results depend on the provider, model, prompt contents, and cache TTL. Speed and cost are not guaranteed.

Configure your own HTTPS provider in Settings → Models. Manual newapi/sub2api channel configuration and account adapters are covered by local HTTP integration tests; hosted activation requires your own service endpoints. Keys use the application's own keychain service. Pi configuration and sessions are stored under `<app-data>/pi-agent/`.

## Updates and platforms

The app does not bundle Pi or Node.js (which keeps the download small): on first launch it installs the locked 1.5.0 release into user data, using the machine's Node.js 22.19+ or a Node.js it downloads and checks against nodejs.org's checksums; progress shows over the composer. Its independent updater checks the official Pi release endpoint after 30 seconds and then every six hours, installing into user data for new sessions. Desktop updates have their own release channel and Ed25519 signature verification. The production GitHub feed and a real installer download have passed verification through the app's update backend. See [auto-update](docs/auto-update.md) and [release](docs/release.md).

**[Download pi-desktop 0.1.2+3](https://github.com/zkldwxz/pi-desktop/releases/tag/pi-v0.1.2)**: macOS Apple Silicon and Intel ZIP/DMG packages, plus a Windows x64 installer. All three Actions builds passed; the Apple Silicon app passes signature and runtime checks and launches with isolated data. macOS packages are ad-hoc signed and not notarized; Windows is unsigned. Visual GUI checks and interactive Windows installation remain unverified. No Linux desktop packages are built for this release.

GitHub checks passed static analysis, Pi runtime/integration tests, 304 focused desktop tests and a real Dart language-server smoke test. The repository is [zkldwxz/pi-desktop](https://github.com/zkldwxz/pi-desktop).

Local projects are supported. Direct SSH Pi sessions use a remote-installed Pi and Node with batch/key authentication. A real SSH stub turn has been verified; broader remote workflows remain to be validated. The remote IDE server is not in the app: the first time an SSH project is opened on a Linux x64 or arm64 host, the app downloads it from the project's GitHub release (`server-<version>`, listed in a small `servers.json` the app carries) and checks its SHA-256. Windows and macOS hosts are not covered yet; remote language servers are not guaranteed. A real Dart language-server smoke check covered diagnostics, hover, completion and rename.

## Compare cache behavior

To compare with upstream reproducibly, use the same provider endpoint, model and parameters, credentials/account, prompt and tool definitions, workspace, and conversation sequence. Record versions and timestamps, cache TTL and provider settings. Start with cold caches, then repeat the same turns in the same session within the TTL; repeat independent runs and record each request's input, cache-read and cache-write tokens as reported by the provider. Compare totals and distributions with the provider's definitions, and disclose missing metrics and changes in prompts or timing. Do not infer a universal hit rate, latency or cost advantage from one run.

## Develop

Requirements: Flutter **3.47.5**, Node.js **22.19+**, and the platform's Flutter desktop toolchain; macOS builds require full Xcode.

```sh
flutter pub get
npm ci --prefix runtime/pi --ignore-scripts
flutter run -d macos  # or windows
```

`pi.path` and `pi.nodePath` in Settings → General override the CLI and Node executable. Development overrides include `PI_DESKTOP_RUNTIME_DIR`, `PI_DESKTOP_PI_CLI`, and `PI_DESKTOP_NODE`. Run focused tests for your changes; see [CONTRIBUTING.md](CONTRIBUTING.md).

The application has its own identity and data directory (`~/Library/Application Support/pi-desktop` on macOS and `%APPDATA%/pi-desktop` on Windows). `PI_DESKTOP_DATA_DIR` overrides the data location. Historical documentation may still describe upstream behavior.

[GPL-3.0-only](LICENSE) applies to the application; third-party components retain their own licenses and notices.
