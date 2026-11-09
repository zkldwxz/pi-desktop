import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pi_remote/local.dart' show ClaudeEnvironment;

import '../../platform/data_dir.dart';

/// The Node.js the app downloads where the machine has none that Pi can run
/// on (Pi wants 22.19 or newer).
const piNodeVersion = '24.11.1';
const piNodeMinimum = (22, 19);

/// Which Node.js build runs here, as nodejs.org names it (`darwin`, `linux`,
/// `win`; `x64`, `arm64`); null where there is none.
({String os, String arch})? piNodeTarget([Abi? abi]) =>
    switch (abi ?? Abi.current()) {
      Abi.macosArm64 => (os: 'darwin', arch: 'arm64'),
      Abi.macosX64 => (os: 'darwin', arch: 'x64'),
      Abi.linuxX64 => (os: 'linux', arch: 'x64'),
      Abi.linuxArm64 => (os: 'linux', arch: 'arm64'),
      Abi.windowsX64 => (os: 'win', arch: 'x64'),
      Abi.windowsArm64 => (os: 'win', arch: 'arm64'),
      _ => null,
    };

/// The folder an archive of Node.js unpacks to.
String piNodeBase(({String os, String arch}) target) =>
    'node-v$piNodeVersion-${target.os}-${target.arch}';

/// The archive's file name: a zip on Windows, a tarball elsewhere.
String piNodeArchive(({String os, String arch}) target) =>
    '${piNodeBase(target)}.${target.os == 'win' ? 'zip' : 'tar.gz'}';

/// Node's program in its unpacked [directory].
String piNodeProgram(String directory, ({String os, String arch}) target) =>
    target.os == 'win'
    ? p.join(directory, 'node.exe')
    : p.join(directory, 'bin', 'node');

/// Where the downloaded Node.js is kept.
String piNodeFolder() => p.join(DataDirectory.current.path, 'pi-node');

/// Whether [output] (`node --version`: `v22.19.0`) is new enough for Pi.
bool piNodeVersionOk(String output) {
  final match = RegExp(r'^v(\d+)\.(\d+)\.(\d+)').firstMatch(output.trim());
  if (match == null) return false;
  final major = int.parse(match[1]!);
  final minor = int.parse(match[2]!);
  return major > piNodeMinimum.$1 ||
      (major == piNodeMinimum.$1 && minor >= piNodeMinimum.$2);
}

/// The SHA-256 nodejs.org's SHASUMS256.txt gives [file]; null for none.
String? piNodeChecksum(String sums, String file) {
  final lines = sums
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.endsWith('  $file'))
      .toList();
  if (lines.length != 1) return null;
  final digest = lines.single.substring(
    0,
    lines.single.length - file.length - 2,
  );
  return RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ? digest : null;
}

String? _system;

/// The Node.js the app downloaded, if it is there.
Future<String?> downloadedNode() async {
  final target = piNodeTarget();
  if (target == null) return null;
  final program = piNodeProgram(
    p.join(piNodeFolder(), piNodeBase(target)),
    target,
  );
  return await File(program).exists() ? program : null;
}

/// A Node.js of the machine's that Pi can run on: the first on the login
/// shell's PATH, or in the places installers use.
Future<String?> systemNode() async {
  if (_system != null) return _system;
  final environment = await ClaudeEnvironment.of();
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final name = Platform.isWindows ? 'node.exe' : 'node';
  final separator = Platform.isWindows ? ';' : ':';
  final directories = <String>{
    ...(environment['PATH'] ?? Platform.environment['PATH'] ?? '')
        .split(separator)
        .where((directory) => directory.isNotEmpty),
    if (!Platform.isWindows) ...[
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      if (home != null) p.join(home, '.volta', 'bin'),
    ],
    if (Platform.isWindows) ...[
      r'C:\Program Files\nodejs',
      if (Platform.environment['ProgramFiles'] case final files?)
        p.join(files, 'nodejs'),
    ],
  };
  for (final directory in directories) {
    final program = p.join(directory, name);
    if (!await File(program).exists()) continue;
    try {
      final result = await Process.run(program, const [
        '--version',
      ]).timeout(const Duration(seconds: 8));
      if (result.exitCode == 0 && piNodeVersionOk('${result.stdout}')) {
        return _system = program;
      }
    } on Object {
      // Not one that runs.
    }
  }
  return null;
}
