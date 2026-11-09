import 'dart:io';

import 'package:path/path.dart' as p;

import 'pi_node_io.dart';
import 'pi_transport.dart' show PiRuntimeSettings;

Future<Directory> findPiRuntime() async {
  final executable = p.dirname(Platform.resolvedExecutable);
  for (final path in [
    Platform.environment['PI_DESKTOP_RUNTIME_DIR'],
    if (Platform.isMacOS) p.join(executable, '..', 'Resources', 'pi-runtime'),
    p.join(executable, 'data', 'pi-runtime'),
    p.join(Directory.current.path, 'runtime', 'pi'),
  ].whereType<String>()) {
    final directory = Directory(p.normalize(path));
    if (await File(p.join(directory.path, 'desktop-extension.mjs')).exists()) {
      return directory;
    }
  }
  throw StateError(
    'Pi runtime is missing. Run npm ci --prefix runtime/pi, or reinstall pi-desktop.',
  );
}

/// The Pi the runtime folder carries, if any: a checkout's `npm ci --prefix
/// runtime/pi`, or an older bundle. The app carries none of its own now (see
/// pi_runtime_install.dart).
Future<String?> bundledPiCli(Directory runtime) async {
  final cli = File(
    p.join(
      runtime.path,
      'node_modules',
      '@earendil-works',
      'pi-coding-agent',
      'dist',
      'bundle',
      'cli.js',
    ),
  );
  return await cli.exists() ? cli.path : null;
}

/// The Node that runs Pi: the one set, the runtime folder's own, the one
/// downloaded, one of the machine's that is new enough; else `node`.
Future<String> piNodeExecutable(Directory runtime) async {
  final bundled = File(
    p.join(runtime.path, Platform.isWindows ? 'node.exe' : 'node'),
  );
  return PiRuntimeSettings.nodePath() ??
      Platform.environment['PI_DESKTOP_NODE'] ??
      (await bundled.exists() ? bundled.path : null) ??
      await downloadedNode() ??
      await systemNode() ??
      'node';
}
