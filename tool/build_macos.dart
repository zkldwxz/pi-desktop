// Builds the macOS distribution, one for Apple silicon (arm64) and one for
// Intel (x64): each a .dmg that ships the app and a .zip the app updates
// itself from (lib/update/). Flutter builds the app once, universal; each
// is that app thinned to one architecture (ditto --arch), about half its
// size. Run from anywhere in the repository:
//
//   dart run tool/build_macos.dart                build, then package
//   dart run tool/build_macos.dart --skip-build   package what is built
//   dart run tool/build_macos.dart --build-only   build, not package (CI,
//                                                while the remote server is
//                                                still building)
//   dart run tool/build_macos.dart --remote-built build the app, take the
//                                                remote server already in
//                                                build/remote/ (CI builds
//                                                it once, for both apps)
//   dart run tool/build_macos.dart --channel      the channel build
//                                                (PI_DESKTOP_CHANNEL; lib/channel/),
//                                                its files named -channel
//   dart run tool/build_macos.dart --remote-release [VERSION]
//                                                take the remote server
//                                                published (the newest
//                                                without VERSION; tool/
//                                                fetch_remote_server.dart)
//                                                instead of building one
//
// They land in build/installers/: pi-desktop-<version>-<arch>.dmg and
// pi-desktop-<version>-mac-<arch>.zip, arch arm64 or x64 (the channel
// build's ending in -channel: pi-desktop-<version>-<arch>-channel.dmg…); beside them,
// Local remote server builds are carried in the app. With --remote-release,
// the app instead downloads the published builds from their manifest.
//
// The Dart code's symbols are saved as it is built, to build/symbols/
// App.macos.symbols (universal: the App framework's executable before it is
// stripped): a jank sample (lib/diagnostics/jank_sample.dart) names its
// frames by their offsets in App, which tool/symbolize_jank_sample.dart
// turns into functions with that file. The app ships stripped, as before.
//
// Signed with a Developer ID and notarised when the environment says how
// (docs/release.md has how to get each):
//
//   PI_DESKTOP_MACOS_SIGN_IDENTITY  the certificate's SHA-1 (40 hex digits, as
//                                `security find-identity -v -p codesigning`
//                                lists it) or its name, "Developer ID
//                                Application: <name> (<team>)"; in a
//                                keychain searched
//   PI_DESKTOP_NOTARY_KEY           an App Store Connect API key (.p8), its path
//   PI_DESKTOP_NOTARY_KEY_ID        that key's ID
//   PI_DESKTOP_NOTARY_ISSUER        its issuer ID
//
// Without an identity the app is signed ad hoc, again: files added after
// Flutter signed it have to be sealed too, or the
// signature is broken and the app refuses the update (lib/update/
// installer_io.dart checks it). Ad hoc, it opens on this machine; Gatekeeper
// refuses it on anyone else's ("pi-desktop is damaged and can't be opened").
// Signed but not notarised, it is refused too, with another message.
import 'dart:convert';
import 'dart:io';

/// Where the .app flutter leaves behind goes, and where the disk image is
/// written. Under build/, which the repository already ignores and flutter
/// clean already removes.
const _bundleRelative = 'build/macos/Build/Products/Release/pi-desktop.app';
const _installersRelative = 'build/installers';
const _symbolsRelative = 'build/symbols';

/// The App framework's executable: the Dart code, compiled.
const _appExecutable = 'Contents/Frameworks/App.framework/Versions/A/App';

/// Where each architecture's app is made of the universal one.
const _thinRelative = 'build/macos/thin';

/// The architectures shipped: ditto's and lipo's name for each, and the one
/// in file names and in the manifest's platforms (`macos-arm64`).
const _architectures = {'arm64': 'arm64', 'x86_64': 'x64'};

/// Where the remote server is built (tool/build_remote_server.dart).
const _remoteRelative = 'build/remote';

/// Where one published is taken to (tool/fetch_remote_server.dart).
const _remoteReleaseRelative = 'build/remote-release';

/// The browser's native messaging host, beside the app's executable.
const _browserHost = 'pi-desktop-browser-host';

/// What has to be in the .app for it to start. As on Windows, a build that
/// failed late still leaves an .app behind that looks complete — these are
/// what tell the difference.
const _required = [
  'Contents/MacOS/pi-desktop',
  'Contents/Info.plist',
  'Contents/Frameworks/FlutterMacOS.framework',
  'Contents/Frameworks/App.framework',
  'Contents/Frameworks/App.framework/Resources/flutter_assets',
  // The terminal's native half (pi_pty's hook/build.dart builds it).
  'Contents/Frameworks/pi_pty.framework',
  // Finder's context menu (macos/FinderExtension), which Settings → General
  // turns on.
  'Contents/PlugIns/FinderExtension.appex',
  // What Chrome runs for pi-desktop's extension (macos/BrowserBridge).
  'Contents/MacOS/$_browserHost',
  // The server remote projects run on their host (Linux and macOS, x64 and
  // arm64; tool/build_remote_server.dart): which build, and where it is
  // downloaded from.
  'Contents/Resources/remote/VERSION',
];

Future<void> main(List<String> arguments) async {
  if (!Platform.isMacOS) {
    _fail(
      'This builds the macOS disk image, and only runs on macOS.\n'
      'On Windows, use tool/build_windows.dart.',
    );
  }
  final skipBuild = arguments.contains('--skip-build');
  final buildOnly = arguments.contains('--build-only');
  if (skipBuild && buildOnly) {
    _fail('--skip-build and --build-only leave nothing to do.');
  }
  final channel = arguments.contains('--channel');
  final edition = channel ? '-channel' : '';
  final releaseAt = arguments.indexOf('--remote-release');
  final remoteRelease = releaseAt < 0
      ? null
      : releaseAt + 1 < arguments.length &&
            !arguments[releaseAt + 1].startsWith('--')
      ? arguments[releaseAt + 1]
      : 'latest';
  final remoteBuilt =
      skipBuild ||
      remoteRelease != null ||
      arguments.contains('--remote-built');

  // The script lives in tool/, so the repository is one level above it.
  final root = File.fromUri(Platform.script).parent.parent.absolute;
  final bundle = Directory('${root.path}/$_bundleRelative');
  final installers = Directory('${root.path}/$_installersRelative');
  final remote = Directory(
    '${root.path}/${remoteRelease == null ? _remoteRelative : _remoteReleaseRelative}',
  );
  final version = _readVersion(File('${root.path}/pubspec.yaml'));

  if (!skipBuild) {
    _step('Building the Release app${channel ? ' (the channel build)' : ''}');
    await _run('flutter', [
      'build',
      'macos',
      '--release',
      if (channel) '--dart-define=PI_DESKTOP_CHANNEL=true',
      for (final name in [
        'PI_DESKTOP_UPDATE_URL',
        'PI_DESKTOP_UPDATE_PUBLIC_KEY',
        'PI_DESKTOP_UPDATE_ALLOWED_ORIGINS',
        'PI_DESKTOP_UPDATE_ALLOW_LOCALHOST',
      ])
        if (Platform.environment.containsKey(name))
          '--dart-define=$name=${Platform.environment[name]}',
      // Its symbols kept, to be saved before it is stripped below.
      '--extra-gen-snapshot-options=--no-strip',
    ], root.path);
    _step('Saving the Dart code\'s symbols, then stripping them');
    final app = File('${bundle.path}/$_appExecutable');
    final symbols = Directory('${root.path}/$_symbolsRelative')
      ..createSync(recursive: true);
    app.copySync('${symbols.path}/App.macos.symbols');
    // -x: the local symbols, the Dart code's (as flutter strips it).
    await _run('strip', ['-x', app.path, '-o', app.path], root.path);
    if (buildOnly) {
      _step('Built: --skip-build packages it');
      return;
    }
  } else {
    _step('Using the app already built');
  }
  if (remoteRelease != null) {
    _step('Taking the remote server published');
    await _run(Platform.resolvedExecutable, [
      'run',
      'tool/fetch_remote_server.dart',
      remoteRelease,
      '--out',
      remote.path,
    ], root.path);
  } else if (!remoteBuilt) {
    _step('Building the remote server');
    await _run(Platform.resolvedExecutable, [
      'run',
      'tool/build_remote_server.dart',
      '--out',
      remote.path,
    ], root.path);
  }

  // Put server resources into the app before signing.
  _step('Putting the remote server in the app');
  final remoteVersion = _bundleRemote(
    remote,
    Directory('${bundle.path}/Contents/Resources/remote'),
    published: remoteRelease != null,
  );

  _step('Checking the app');
  _checkBundle(bundle, _required);
  await _checkUniversal(bundle);
  // An app built before pubspec.yaml's version changed (--skip-build) would
  // be shipped as the new version, and offered as an update to itself.
  final bundleId = await _plist(bundle, 'CFBundleIdentifier');
  if (bundleId != 'dev.pi.desktop') {
    _fail('Expected bundle identifier dev.pi.desktop, found $bundleId.');
  }
  final built = await _plist(bundle, 'CFBundleShortVersionString');
  final build = await _plist(bundle, 'CFBundleVersion');
  if (built != version.marketing || build != version.build) {
    _fail(
      'The app is version $built ($build), pubspec.yaml says '
      '${version.full}.\nBuild it again, without --skip-build.',
    );
  }

  // Signed again whatever the identity: flutter's signature does not
  // cover the remote server's files, put in after it, and thinning an app
  // breaks the signature of every binary in it.
  final signing = _Signing.fromEnvironment(root) ?? _Signing(root, '-', null);
  if (signing.adHoc) {
    _step('Signing ad hoc: \$PI_DESKTOP_MACOS_SIGN_IDENTITY is not set');
    stdout.writeln(
      '  It opens on this machine only: Gatekeeper refuses it anywhere\n'
      '  else.',
    );
  } else if (signing.notary == null) {
    _step('Not notarising: \$PI_DESKTOP_NOTARY_KEY is not set');
    stdout.writeln(
      '  Signed but not notarised, the app is still refused by\n'
      '  Gatekeeper on other machines.',
    );
  }

  installers.createSync(recursive: true);
  // Each image is notarised, stapled and zipped while the next is made.
  final finishing = <Future<List<File>>>[];
  for (final MapEntry(key: lipoArch, value: arch) in _architectures.entries) {
    _step('Making the $arch app');
    final app = Directory('${root.path}/$_thinRelative/$arch/pi-desktop.app');
    if (app.parent.existsSync()) app.parent.deleteSync(recursive: true);
    app.parent.createSync(recursive: true);
    await _run('ditto', ['--arch', lipoArch, bundle.path, app.path], root.path);
    await _checkArchitecture(app, lipoArch);
    _step('Bundling the Pi runtime files for $arch');
    final runtime = Directory('${app.path}/Contents/Resources/pi-runtime');
    if (runtime.existsSync()) runtime.deleteSync(recursive: true);
    await _run(Platform.resolvedExecutable, [
      'run',
      'tool/bundle_pi_runtime.dart',
      '--target',
      runtime.path,
      '--platform',
      'macos',
      '--arch',
      arch,
    ], root.path);
    _step(
      'Signing the $arch app${signing.adHoc ? '' : ' as ${signing.identity}'}',
    );
    await signing.signApp(app);

    _step('Making the $arch disk image');
    final dmg = File(
      '${installers.path}/pi-desktop-${version.marketing}-$arch$edition.dmg',
    );
    // hdiutil needs no Finder automation or third-party packaging tool.
    final staging = await Directory.systemTemp.createTemp('pi-desktop-dmg-');
    try {
      await _run('ditto', [
        app.path,
        '${staging.path}/pi-desktop.app',
      ], root.path);
      await Link('${staging.path}/Applications').create('/Applications');
      if (dmg.existsSync()) dmg.deleteSync();
      await _run('hdiutil', [
        'create',
        '-volname',
        'pi-desktop ${version.marketing}',
        '-srcfolder',
        staging.path,
        '-format',
        'ULMO',
        dmg.path,
      ], root.path);
    } finally {
      await staging.delete(recursive: true);
    }
    if (!signing.adHoc) await signing.sign(dmg.path);
    finishing.add(
      _finish(signing, installers, version.marketing, edition, arch, app, dmg),
    );
  }
  final made = [for (final files in await Future.wait(finishing)) ...files];

  // None when published already (--remote-release).
  final downloads = Directory('${installers.path}/remote/$remoteVersion');
  final builds = [
    for (final file in remote.listSync())
      if (file is File && file.path.endsWith('.gz')) file,
  ];
  if (builds.isNotEmpty) {
    _step('Putting the remote server\'s builds beside them');
    downloads.createSync(recursive: true);
  }
  final servers = [
    for (final file in builds)
      file.copySync('${downloads.path}/${file.uri.pathSegments.last}'),
  ];

  _step('Done');
  for (final file in [...made, ...servers]) {
    final mb = (file.lengthSync() / (1024 * 1024)).toStringAsFixed(1);
    stdout.writeln('  ${file.path}  ($mb MB)');
  }
  stdout.writeln('Release artifacts are in ${installers.path}.');
}

/// Notarises [dmg] (and so the [arch] app in it) where [signing] says to,
/// staples the ticket to both, and zips the app for updates: the image and
/// the archive.
Future<List<File>> _finish(
  _Signing signing,
  Directory installers,
  String marketing,
  String edition,
  String arch,
  Directory app,
  File dmg,
) async {
  if (!signing.adHoc && signing.notary != null) {
    // Notarising the image notarises the app in it too: the ticket
    // stapled to each is the one for its own signature.
    _step('Notarising the $arch disk image (a few minutes)');
    await signing.notarise(dmg);
    await signing.staple(dmg.path);
    await signing.staple(app.path);
    _step('Notarised the $arch disk image');
  }

  _step('Making the $arch update archive');
  // What the app downloads to update itself: the .app (stapled when it
  // was notarised), zipped as Finder would (ditto keeps its symlinks,
  // permissions and extended attributes, which a framework's signature
  // depends on).
  final zip = File(
    '${installers.path}/pi-desktop-$marketing-mac-$arch$edition.zip',
  );
  if (zip.existsSync()) zip.deleteSync();
  await _run('ditto', [
    '-c',
    '-k',
    '--sequesterRsrc',
    '--keepParent',
    app.path,
    zip.path,
  ], signing.root.path);
  return [dmg, zip];
}

/// Signing with a Developer ID, and notarising, as the environment says
/// (the variables at the top of this file).
class _Signing {
  _Signing(this.root, this.identity, this.notary);

  /// Null when no identity is given (the app is then signed ad hoc).
  static _Signing? fromEnvironment(Directory root) {
    final environment = Platform.environment;
    final identity = environment['PI_DESKTOP_MACOS_SIGN_IDENTITY'] ?? '';
    if (identity.isEmpty) return null;
    final key = environment['PI_DESKTOP_NOTARY_KEY'] ?? '';
    final keyId = environment['PI_DESKTOP_NOTARY_KEY_ID'] ?? '';
    final issuer = environment['PI_DESKTOP_NOTARY_ISSUER'] ?? '';
    if (key.isEmpty) return _Signing(root, identity, null);
    if (keyId.isEmpty || issuer.isEmpty) {
      _fail(
        '\$PI_DESKTOP_NOTARY_KEY is set: \$PI_DESKTOP_NOTARY_KEY_ID and '
        '\$PI_DESKTOP_NOTARY_ISSUER have to be too.',
      );
    }
    if (!File(key).existsSync()) _fail('No API key at $key.');
    return _Signing(root, identity, (key: key, keyId: keyId, issuer: issuer));
  }

  final Directory root;

  /// A Developer ID's name or SHA-1; `-` for ad hoc.
  final String identity;
  bool get adHoc => identity == '-';

  final ({String key, String keyId, String issuer})? notary;

  /// Signs the .app inside out: its frameworks, the browser's host, then the
  /// Finder extension, then the app around them ([sign] says with what). The
  /// host's own signature, Xcode's ad hoc, would not be notarised.
  ///
  /// Not `codesign --deep`: it would give the Finder extension the app's
  /// entitlements, sandbox off, and the system refuses to load an extension
  /// that is not sandboxed. The extension takes its own.
  ///
  /// And the app takes macos/Runner/Release.entitlements, not none: those
  /// turn the sandbox off, which this app needs (it runs the Claude Code
  /// CLI as a child process and reads its sessions under ~/.claude, and
  /// replaces itself to update). Signed without them it would fail at
  /// runtime, not here. Not DebugProfile's either: allow-jit and
  /// network.server are for debugging.
  ///
  /// Once released signed, an update has to be signed by the same team:
  /// the app checks (lib/update/installer_io.dart).
  Future<void> signApp(Directory app) async {
    final frameworks = Directory('${app.path}/Contents/Frameworks');
    for (final entry in frameworks.listSync()) {
      if (entry.path.endsWith('.framework') || entry.path.endsWith('.dylib')) {
        await sign(entry.path);
      }
    }
    // Node and native npm modules must be signed before the enclosing app.
    final runtime = Directory('${app.path}/Contents/Resources/pi-runtime');
    await for (final entity in runtime.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final file = await entity.open();
      final header = await file.read(4);
      await file.close();
      if (header.length != 4) continue;
      final magic = header
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (const {
        'cffaedfe',
        'feedfacf',
        'cafebabe',
        'cafebabf',
        'bebafeca',
        'bfbafeca',
      }.contains(magic)) {
        await sign(entity.path);
      }
    }
    await sign('${app.path}/Contents/MacOS/$_browserHost');
    await sign(
      '${app.path}/Contents/PlugIns/FinderExtension.appex',
      entitlements: 'macos/FinderExtension/FinderExtension.entitlements',
    );
    await sign(app.path, entitlements: 'macos/Runner/Release.entitlements');
    await _run('codesign', [
      '--verify',
      '--deep',
      '--strict',
      '--verbose=2',
      app.path,
    ], root.path);
  }

  /// The hardened runtime and a secure timestamp only with a Developer ID,
  /// which notarising asks for. Not ad hoc: the hardened runtime brings
  /// library validation, which an ad hoc app fails on its own frameworks
  /// (they have no Team ID to share with it), and dyld refuses to load
  /// FlutterMacOS.framework at launch.
  Future<void> sign(String path, {String? entitlements}) => _run('codesign', [
    '--force',
    if (!adHoc) ...['--options', 'runtime', '--timestamp'],
    if (entitlements != null) ...['--entitlements', entitlements],
    '--sign',
    identity,
    path,
  ], root.path);

  /// Sends [file] to Apple's notary service and waits for its verdict;
  /// stops with Apple's log when it is not accepted.
  Future<void> notarise(File file) async {
    final notary = this.notary!;
    final credentials = [
      '--key',
      notary.key,
      '--key-id',
      notary.keyId,
      '--issuer',
      notary.issuer,
    ];
    final result = await Process.run('xcrun', [
      'notarytool',
      'submit',
      file.path,
      ...credentials,
      '--wait',
      '--output-format',
      'json',
    ]);
    final Map<String, Object?> answer;
    try {
      answer = jsonDecode('${result.stdout}') as Map<String, Object?>;
    } on FormatException {
      _fail('notarytool answered:\n${result.stdout}\n${result.stderr}');
    }
    stdout.writeln('  ${answer['status']} (submission ${answer['id']})');
    if (answer['status'] != 'Accepted') {
      final log = await Process.run('xcrun', [
        'notarytool',
        'log',
        '${answer['id']}',
        ...credentials,
      ]);
      _fail('Apple did not notarise ${file.path}:\n${log.stdout}');
    }
  }

  /// Staples the notarisation ticket to [path], trying again for about
  /// twelve minutes: stapler fetches the ticket from Apple's CloudKit, which
  /// can drop the connection (-1005, stapler's error 68) for minutes on
  /// end, or not have the ticket yet just after it is accepted. Within two
  /// and a half minutes it had failed builds four times in a week (all the
  /// failures there were), while notarising never did.
  Future<void> staple(String path) async {
    const waits = [15, 30, 60, 90, 120, 180, 240];
    for (var attempt = 1; ; attempt++) {
      stdout.writeln('  \$ xcrun stapler staple $path');
      final result = await Process.run('xcrun', ['stapler', 'staple', path]);
      if (result.exitCode == 0) return;
      stdout.writeln('${result.stdout}'.trim());
      stderr.writeln('${result.stderr}'.trim());
      if (attempt > waits.length) {
        _fail('stapler exited with code ${result.exitCode}, $attempt times.');
      }
      final wait = waits[attempt - 1];
      stdout.writeln(
        '  Trying again in $wait seconds '
        '(attempt ${attempt + 1} of ${waits.length + 1})',
      );
      await Future<void>.delayed(Duration(seconds: wait));
    }
  }
}

/// Include local builds directly; only published releases use download URLs.
String _bundleRemote(
  Directory remote,
  Directory target, {
  required bool published,
}) {
  final versionFile = File('${remote.path}/VERSION');
  if (!versionFile.existsSync()) {
    _fail(
      'No remote server in ${remote.path}; build it first or use --remote-release.',
    );
  }
  final version = versionFile.readAsStringSync().trim();
  if (version.isEmpty || version.contains(RegExp(r'[^A-Za-z0-9._+-]'))) {
    _fail('Invalid remote server version in ${versionFile.path}.');
  }
  final manifest = File('${remote.path}/servers.json');
  final builds = remote.existsSync()
      ? remote
            .listSync()
            .whereType<File>()
            .where(
              (file) =>
                  RegExp(r'^pi-desktop-server-(linux|darwin|windows)-(arm64|x64)$')
                      .hasMatch(file.uri.pathSegments.last),
            )
            .toList()
      : <File>[];
  if (published && !manifest.existsSync()) {
    _fail('No published remote server manifest in ${remote.path}.');
  }
  if (!published && builds.isEmpty) {
    _fail(
      'No local remote server binaries in ${remote.path}. Build them first.',
    );
  }
  if (target.existsSync()) target.deleteSync(recursive: true);
  target.createSync(recursive: true);
  versionFile.copySync('${target.path}/VERSION');
  if (published) {
    manifest.copySync('${target.path}/servers.json');
  } else {
    for (final file in builds) {
      file.copySync('${target.path}/${file.uri.pathSegments.last}');
    }
  }
  return version;
}

/// The version pubspec.yaml carries, as `1.0.0+1`: the whole of it, the part
/// the app shows (CFBundleShortVersionString), and the build number after it
/// (CFBundleVersion).
({String full, String marketing, String build}) _readVersion(File pubspec) {
  final text = pubspec.readAsStringSync();
  final match = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(text);
  if (match == null) {
    _fail('No "version:" line in ${pubspec.path}');
  }
  final full = match.group(1)!;
  final plus = full.indexOf('+');
  return (
    full: full,
    marketing: plus < 0 ? full : full.substring(0, plus),
    build: plus < 0 ? '0' : full.substring(plus + 1),
  );
}

/// The executables in [app]: its own, the browser's host, the Finder
/// extension's, and each framework's.
List<String> _executables(Directory app) => [
  '${app.path}/Contents/MacOS/pi-desktop',
  '${app.path}/Contents/MacOS/$_browserHost',
  '${app.path}/Contents/PlugIns/FinderExtension.appex/Contents/MacOS/'
      'FinderExtension',
  // A framework's executable is named as the framework: X.framework/X.
  for (final framework in Directory(
    '${app.path}/Contents/Frameworks',
  ).listSync())
    if (framework.path.endsWith('.framework'))
      '${framework.path}/${framework.path.split('/').last.split('.').first}',
];

/// Stops unless every executable in [app] runs on both Apple silicon and
/// Intel: the app each architecture's is thinned from. A framework built
/// for one alone would be missing from the other's, which fails only when
/// it loads it.
Future<void> _checkUniversal(Directory app) async {
  final executables = _executables(app);
  final missing = <String>[];
  for (final executable in executables) {
    final result = await Process.run('lipo', ['-archs', executable]);
    final archs = '${result.stdout}'.trim().split(' ');
    if (result.exitCode != 0 ||
        !archs.contains('arm64') ||
        !archs.contains('x86_64')) {
      missing.add('  $executable: ${'${result.stdout}'.trim()}');
    }
  }
  if (missing.isNotEmpty) {
    _fail(
      'Not universal (arm64 and x86_64), so not for every Mac:\n'
      '${missing.join('\n')}',
    );
  }
  stdout.writeln(
    '  Universal: arm64 and x86_64, ${executables.length} '
    'executables.',
  );
}

/// Stops unless every executable in [app] is for [lipoArch] alone: what
/// `ditto --arch` should have left.
Future<void> _checkArchitecture(Directory app, String lipoArch) async {
  final wrong = <String>[];
  for (final executable in _executables(app)) {
    final result = await Process.run('lipo', ['-archs', executable]);
    if ('${result.stdout}'.trim() != lipoArch) {
      wrong.add('  $executable: ${'${result.stdout}'.trim()}');
    }
  }
  if (wrong.isNotEmpty) {
    _fail('Not $lipoArch alone:\n${wrong.join('\n')}');
  }
}

/// [key] of the app's Info.plist; null when it has none.
Future<String?> _plist(Directory app, String key) async {
  final result = await Process.run('/usr/libexec/PlistBuddy', [
    '-c',
    'Print :$key',
    '${app.path}/Contents/Info.plist',
  ]);
  return result.exitCode == 0 ? '${result.stdout}'.trim() : null;
}

/// Stops unless [directory] holds every one of [required].
void _checkBundle(Directory directory, List<String> required) {
  if (!directory.existsSync()) {
    _fail(
      'No app at ${directory.path}.\n'
      'Build it first, without --skip-build.',
    );
  }
  final missing = [
    for (final item in required)
      if (FileSystemEntity.typeSync('${directory.path}/$item') ==
          FileSystemEntityType.notFound)
        item,
  ];
  if (missing.isEmpty) {
    stdout.writeln('  ${directory.path} looks complete.');
    return;
  }
  _fail(
    'The app at ${directory.path} is incomplete; missing:\n'
    '${missing.map((item) => '  $item').join('\n')}\n'
    '\n'
    'A build that failed late leaves an app that looks whole and will not\n'
    'start. Build it again.',
  );
}

/// Runs [executable], printing the command; stops the script on a non-zero
/// exit.
Future<void> _run(
  String executable,
  List<String> arguments,
  String workingDirectory,
) async {
  stdout.writeln('  \$ $executable ${arguments.join(' ')}');
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  final output = '${result.stdout}'.trim();
  if (output.isNotEmpty) stdout.writeln(output);
  final error = '${result.stderr}'.trim();
  if (error.isNotEmpty) stderr.writeln(error);
  if (result.exitCode != 0) {
    _fail('$executable exited with code ${result.exitCode}.');
  }
}

void _step(String message) => stdout.writeln('\n==> $message');

Never _fail(String message) {
  stderr.writeln('\n$message');
  exit(1);
}
