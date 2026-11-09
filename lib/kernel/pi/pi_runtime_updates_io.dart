import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';
import 'pi_runtime_paths_io.dart';
import 'pi_runtime_updates.dart';

Future<PiRuntimeUpdateInfo> piRuntimeCommand(String command) async {
  final runtime = await findPiRuntime();
  final process = await Process.start(await piNodeExecutable(runtime), [
    p.join(runtime.path, 'runtime-manager.mjs'),
    command,
    p.join(DataDirectory.current.path, 'pi-runtime'),
  ], workingDirectory: runtime.path);
  final output = utf8.decoder.bind(process.stdout).join();
  var diagnostic = '';
  final stderr = process.stderr.transform(utf8.decoder).listen((text) {
    diagnostic = '$diagnostic$text';
    if (diagnostic.length > 4096) {
      diagnostic = diagnostic.substring(diagnostic.length - 4096);
    }
  });
  try {
    final code = await process.exitCode.timeout(
      Duration(minutes: command == 'update' ? 5 : 1),
    );
    final text = await output;
    if (code != 0) {
      throw StateError(
        diagnostic.trim().isEmpty
            ? 'Pi runtime update failed ($code)'
            : diagnostic.trim(),
      );
    }
    final result = jsonDecode(text) as Map<String, dynamic>;
    return PiRuntimeUpdateInfo(
      version: result['version'] as String,
      latest: result['latest'] as String?,
      cli: result['cli'] as String?,
      managed: result['managed'] == true,
    );
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    throw StateError('Pi runtime update timed out');
  } finally {
    await stderr.cancel();
  }
}

/// Reading the active pointer needs no process launch or network access.
Future<String?> managedPiCli() async {
  try {
    final root = p.join(DataDirectory.current.path, 'pi-runtime');
    final version = (await File(
      p.join(root, 'current-version'),
    ).readAsString()).trim();
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) return null;
    final runtime = await findPiRuntime();
    final installedVersion = version.split('.').map(int.parse).toList();
    final baseVersion = (await _baseVersion(runtime))
        .split('.')
        .map(int.parse)
        .toList();
    for (var i = 0; i < 3; i++) {
      if (installedVersion[i] < baseVersion[i]) return null;
      if (installedVersion[i] > baseVersion[i]) break;
    }
    final manifest = File(
      p.join(
        root,
        'releases',
        version,
        'node_modules',
        '@earendil-works',
        'pi-coding-agent',
        'package.json',
      ),
    );
    final json = jsonDecode(await manifest.readAsString()) as Map;
    if (json['name'] != '@earendil-works/pi-coding-agent' ||
        json['version'] != version) {
      return null;
    }
    final cli = File(p.join(manifest.parent.path, 'dist', 'bundle', 'cli.js'));
    return await cli.exists() ? cli.path : null;
  } on Object {
    return null;
  }
}

/// The Pi release the app is made for: the one beside the runtime files (a
/// checkout's, an older bundle's), else what the runtime's package.json pins.
Future<String> _baseVersion(Directory runtime) async {
  try {
    final json = jsonDecode(
      await File(
        p.join(
          runtime.path,
          'node_modules',
          '@earendil-works',
          'pi-coding-agent',
          'package.json',
        ),
      ).readAsString(),
    ) as Map;
    return '${json['version']}';
  } on Object {
    final json = jsonDecode(
      await File(p.join(runtime.path, 'package.json')).readAsString(),
    ) as Map;
    final pin =
        '${(json['dependencies'] as Map)['@earendil-works/pi-coding-agent']}';
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(pin)) {
      throw StateError('The runtime does not pin a stable Pi release');
    }
    return pin;
  }
}
