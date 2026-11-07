# Contributing to pi-desktop

pi-desktop is a fork of [BaoCode](https://github.com/baocode-dev/baocode) using the Pi coding agent. Use the [fork repository](https://github.com/zkldwxz/pi-desktop) for fork-specific changes.

## Develop

See the [README](README.md) for prerequisites and runtime configuration. With Flutter 3.47.5, Dart `^3.13.4`, Node.js 22.19 or later, and the desktop toolchain installed:

```sh
flutter pub get
npm ci --prefix runtime/pi --ignore-scripts
flutter run -d macos          # On Windows: flutter run -d windows
```

A macOS build requires full Xcode and its SDKs. The package scripts are `dart run tool/build_macos.dart` and `dart run tool/build_windows.dart`; the fork's desktop packages are for macOS and Windows. See the README for runtime and update configuration.

## Prepare a change

- Discuss substantial changes with the fork maintainer before investing in them. Keep each change focused and explain its purpose and any user-visible effects.
- Follow the surrounding code and preserve existing copyright and license notices, including upstream attribution.
- Format changed Dart files with `dart format`, run `flutter analyze` when appropriate, and run tests relevant to the change. The full test suite is slow; it is not required for every change. For example, Pi runtime changes may warrant `npm test --prefix runtime/pi` and the relevant `flutter test` files listed in the README.
- Add or update tests when needed to verify behavior. Describe the checks you ran and any platform limitations.
- Review and be able to explain your changes, including any generated with assistance from a tool.
- Submit a focused pull request to the fork with a description of the change and its validation.

## License and attribution

The application is distributed under [GPL-3.0-only](LICENSE), inherited from BaoCode. Contributions to it must be compatible with that license. The `bao_editor`, `bao_xterm`, and `bao_pty` packages retain their MIT licenses; consult the license and notices for the files you change. Pi and other third-party components retain their own licenses. Preserve applicable copyright, license, and attribution notices when modifying or redistributing code.
