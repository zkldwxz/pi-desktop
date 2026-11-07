import 'dart:io';

import 'package:path/path.dart' as p;

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

Future<String> piNodeExecutable(Directory runtime) async {
  final bundled = File(
    p.join(runtime.path, Platform.isWindows ? 'node.exe' : 'node'),
  );
  return PiRuntimeSettings.nodePath() ??
      Platform.environment['PI_DESKTOP_NODE'] ??
      (await bundled.exists() ? bundled.path : 'node');
}
