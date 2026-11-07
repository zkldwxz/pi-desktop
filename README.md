# pi-desktop

[简体中文](README_CN.md) · [日本語](README_JA.md) · [Français](README_FR.md) · [Español](README_ES.md)

pi-desktop is a Flutter desktop workspace using the [Pi coding agent](https://github.com/earendil-works/pi). It is an independent fork of [BaoCode](https://github.com/baocode-dev/baocode), retaining its GPL license and upstream notices.

The fork uses Pi's JSONL RPC and native provider protocols for supported standard APIs, avoiding an extra protocol translation layer. It preserves context within a session and tracks cache-read and cache-write usage per request when reported by the provider. Stable prompts and session context may improve cache reuse, but no higher hit rate has been measured: results depend on the provider, model, prompt contents, and cache TTL. Speed and cost are not guaranteed.

Configure your own HTTPS provider in Settings → Models; newapi/sub2api-compatible channel setup remains under test. Keys use the application's own keychain service. Pi configuration and sessions are stored under `<app-data>/pi-agent/`.

## Updates and platforms

The bundled Pi runtime starts from the locked 1.5.0 release. Its independent updater checks the official Pi release endpoint after 30 seconds and then every six hours, installing into user data for new sessions. Desktop updates have their own release channel and Ed25519 signature verification; the fork's update settings are configured for its release, which becomes usable after publication. See [auto-update](docs/auto-update.md) and [release](docs/release.md).

The planned release is **0.1.2+3**, with macOS and Windows packages built through Actions; packaging and installation still need validation. No Linux packages are being built for this release. The repository is [zkldwxz/pi-desktop](https://github.com/zkldwxz/pi-desktop).

Local projects are supported. Direct SSH Pi sessions use a remote-installed Pi and Node with batch/key authentication. A real SSH stub turn has been verified; broader remote workflows remain to be validated. A remote IDE server or remote language server is not automatically installed or guaranteed. A real Dart language-server smoke check covered diagnostics, hover, completion and rename.

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
