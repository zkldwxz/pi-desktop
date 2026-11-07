// Packages the desktop Pi runtime into an empty target directory.
// dart run tool/bundle_pi_runtime.dart --target DIR --platform macos|windows|linux --arch arm64|x64
// PI_DESKTOP_NODE_BINARY can supply a Node binary for the requested target.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const nodeVersion = '24.11.1';

Future<void> main(List<String> args) async {
  try {
    await bundle(args);
  } catch (e) {
    stderr.writeln('Pi runtime bundle: $e');
    exitCode = 1;
  }
}

Future<void> bundle(List<String> args) async {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    if (i + 1 >= args.length ||
        !['--target', '--platform', '--arch'].contains(args[i]) ||
        options.containsKey(args[i]) ||
        args[i + 1].startsWith('--')) {
      throw FormatException(
        'Expected --target DIR --platform macos|windows|linux --arch arm64|x64',
      );
    }
    options[args[i]] = args[i + 1];
  }
  final targetArg = options['--target'];
  final platform = options['--platform'];
  final arch = options['--arch'];
  if (targetArg == null ||
      targetArg.isEmpty ||
      !['macos', 'windows', 'linux'].contains(platform) ||
      !['arm64', 'x64'].contains(arch)) {
    throw FormatException(
      'Expected --target DIR --platform macos|windows|linux --arch arm64|x64',
    );
  }
  final root = p.normalize(
    p.join(p.dirname(Platform.script.toFilePath()), '..'),
  );
  final source = Directory(p.join(root, 'runtime', 'pi'));
  final target = Directory(p.absolute(targetArg));
  if (p.isWithin(source.absolute.path, target.path) ||
      target.path == source.absolute.path ||
      p.isWithin(target.path, source.absolute.path)) {
    throw StateError('Target must be outside the runtime source tree');
  }
  for (final name in [
    'package.json',
    'package-lock.json',
    'desktop-extension.mjs',
    'desktop-config.mjs',
  ]) {
    if (!File(p.join(source.path, name)).existsSync()) {
      throw StateError('Missing runtime file: ${p.join(source.path, name)}');
    }
  }
  final manifest = jsonDecode(
    await File(p.join(source.path, 'package.json')).readAsString(),
  ) as Map<String, dynamic>;
  if ((manifest['dependencies'] as Map?)?['@earendil-works/pi-coding-agent'] !=
      '1.5.0') {
    throw StateError('Runtime must pin @earendil-works/pi-coding-agent 1.5.0');
  }
  if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
          FileSystemEntityType.notFound &&
      (!target.existsSync() ||
          target.listSync().isNotEmpty ||
          Link(target.path).existsSync())) {
    throw StateError(
      'Target must be absent or an empty directory: ${target.path}',
    );
  }
  final temp = await Directory.systemTemp.createTemp('pi-desktop-bundle-');
  try {
    final stage = Directory(p.join(temp.path, 'runtime'))..createSync();
    await copyRuntime(source, stage);
    final browserSource = Directory(p.join(root, 'browser_extension'));
    if (!File(p.join(browserSource.path, 'manifest.json')).existsSync()) {
      throw StateError(
        'Missing browser extension manifest: ${browserSource.path}',
      );
    }
    await copyDirectory(
      browserSource,
      Directory(p.join(stage.path, 'browser-extension')),
      excludeBuild: true,
    );
    final npmPlatform = {
      'macos': 'darwin',
      'windows': 'win32',
      'linux': 'linux',
    }[platform]!;
    await run('npm', [
      'ci',
      '--omit=dev',
      '--ignore-scripts',
      '--os=$npmPlatform',
      '--cpu=$arch',
    ], stage.path);
    if (!File(
      p.join(
        stage.path,
        'node_modules',
        '@earendil-works',
        'pi-coding-agent',
        'package.json',
      ),
    ).existsSync()) {
      throw StateError('npm did not install the Pi coding agent');
    }
    final node = Platform.environment['PI_DESKTOP_NODE_BINARY'];
    final nodeFile = node != null && node.isNotEmpty
        ? File(p.absolute(node))
        : await downloadNode(temp, platform!, arch!);
    await validateNode(nodeFile, platform!, arch!);
    final outputNode = File(
      p.join(stage.path, platform == 'windows' ? 'node.exe' : 'node'),
    );
    await nodeFile.copy(outputNode.path);
    if (platform != 'windows' && !Platform.isWindows) {
      await run('chmod', ['755', outputNode.path], root);
    }
    await target.parent.create(recursive: true);
    if (target.existsSync()) await target.delete();
    // The staging directory may be on another filesystem.
    await copyDirectory(stage, target);
    stdout.writeln('Pi runtime bundled at ${target.path}');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> copyRuntime(Directory source, Directory destination) async {
  const excluded = {
    'node_modules',
    'test',
    'tests',
    '.git',
    '.DS_Store',
    'coverage',
  };
  await for (final entity in source.list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (excluded.contains(name) ||
        name.endsWith('.test.mjs') ||
        name.endsWith('.spec.mjs')) {
      continue;
    }
    final dest = p.join(destination.path, name);
    if (entity is Directory) {
      await Directory(dest).create();
      await copyRuntime(entity, Directory(dest));
    } else if (entity is File) {
      await entity.copy(dest);
    } else {
      throw StateError('Unexpected link in runtime source: ${entity.path}');
    }
  }
}

Future<void> copyDirectory(
  Directory source,
  Directory destination, {
  bool excludeBuild = false,
}) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    if (excludeBuild && p.basename(entity.path) == 'build') continue;
    final dest = p.join(destination.path, p.basename(entity.path));
    if (entity is Link) {
      await Link(dest).create(await entity.target());
    } else if (entity is Directory) {
      await copyDirectory(entity, Directory(dest), excludeBuild: excludeBuild);
    } else if (entity is File) {
      await entity.copy(dest);
      if (!Platform.isWindows) {
        final mode = (await entity.stat()).mode & 0x1ff;
        if (mode & 0x49 != 0) {
          await run('chmod', [mode.toRadixString(8), dest], source.path);
        }
      }
    }
  }
}

Future<void> run(String executable, List<String> args, String cwd) async {
  final result = await Process.run(
    executable,
    args,
    workingDirectory: cwd,
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      args,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
}

Future<File> downloadNode(Directory temp, String platform, String arch) async {
  final os = {'macos': 'darwin', 'windows': 'win', 'linux': 'linux'}[platform]!;
  final base = 'node-v$nodeVersion-$os-$arch';
  final archiveName = '$base.${platform == 'windows' ? 'zip' : 'tar.gz'}';
  final client = HttpClient();
  Future<void> fetch(String name, File dest) async {
    final request = await client.getUrl(
      Uri.https('nodejs.org', '/dist/v$nodeVersion/$name'),
    );
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('Download failed: $name (${response.statusCode})');
    }
    await response.pipe(dest.openWrite());
  }

  final downloads = Directory(p.join(temp.path, 'downloads'))..createSync();
  final extracted = Directory(p.join(temp.path, 'extracted'))..createSync();
  final sums = File(p.join(downloads.path, 'SHASUMS256.txt'));
  final archive = File(p.join(downloads.path, archiveName));
  try {
    await fetch('SHASUMS256.txt', sums);
    await fetch(archiveName, archive);
  } finally {
    client.close(force: true);
  }
  final matching = (await sums.readAsLines())
      .where((line) => line.endsWith('  $archiveName'))
      .toList();
  if (matching.length != 1 ||
      !RegExp(r'^[a-f0-9]{64}  ').hasMatch(matching.single)) {
    throw StateError('Missing official checksum for $archiveName');
  }
  final digest = await sha256.bind(archive.openRead()).first;
  if (digest.toString() != matching.single.substring(0, 64)) {
    throw StateError('Node archive checksum mismatch');
  }
  final member = platform == 'windows' ? '$base/node.exe' : '$base/bin/node';
  if (platform == 'windows') {
    // tar is provided by supported Windows versions and reads zip archives.
    await run('tar', [
      '-xf',
      archive.path,
      '-C',
      extracted.path,
      member,
    ], temp.path);
  } else {
    await run('tar', [
      '-xzf',
      archive.path,
      '-C',
      extracted.path,
      member,
    ], temp.path);
  }
  return File(p.join(extracted.path, member));
}

Future<void> validateNode(File file, String platform, String arch) async {
  if (!await file.exists()) {
    throw StateError('Node binary does not exist: ${file.path}');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length < 64) throw StateError('Invalid Node binary: ${file.path}');
  final data = ByteData.sublistView(bytes);
  bool matches = false;
  if (platform == 'linux' &&
      bytes[0] == 0x7f &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x4c &&
      bytes[3] == 0x46 &&
      bytes[4] == 2 &&
      bytes[5] == 1) {
    matches = data.getUint16(18, Endian.little) == (arch == 'x64' ? 62 : 183);
  } else if (platform == 'windows' && bytes[0] == 0x4d && bytes[1] == 0x5a) {
    final offset = data.getUint32(0x3c, Endian.little);
    if (offset + 6 <= bytes.length &&
        data.getUint32(offset, Endian.little) == 0x4550) {
      matches =
          data.getUint16(offset + 4, Endian.little) ==
          (arch == 'x64' ? 0x8664 : 0xaa64);
    }
  } else if (platform == 'macos') {
    final cpu = arch == 'x64' ? 0x01000007 : 0x0100000c;
    final magic = data.getUint32(0, Endian.big);
    if (magic == 0xcffaedfe) {
      matches = data.getUint32(4, Endian.little) == cpu;
    } else if (magic == 0xcafebabe || magic == 0xcafebabf) {
      final count = data.getUint32(4, Endian.big);
      final stride = magic == 0xcafebabe ? 20 : 32;
      if (count <= 32 && 8 + count * stride <= bytes.length) {
        for (var i = 0; i < count; i++) {
          if (data.getUint32(8 + i * stride, Endian.big) == cpu) matches = true;
        }
      }
    }
  }
  if (!matches) {
    throw StateError(
      'Node binary does not match $platform/$arch: ${file.path}',
    );
  }
  // Node embeds its version in the executable. This also works for cross builds,
  // where executing the supplied target binary is not possible.
  final text = latin1.decode(bytes);
  final versions = RegExp(r'node\.js/v(\d+)\.(\d+)\.(\d+)\b').allMatches(text);
  final valid = versions.any((m) {
    final major = int.parse(m[1]!);
    final minor = int.parse(m[2]!);
    return major > 22 || (major == 22 && minor >= 19);
  });
  if (!valid) {
    throw StateError(
      'Node binary does not contain a supported version (>=22.19.0): ${file.path}',
    );
  }
}
