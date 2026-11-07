import 'dart:convert';
import 'dart:io';

import 'package:pi_desktop/kernel/pi/pi_runtime_updates_io.dart';
import 'package:pi_desktop/platform/data_dir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late DataDirectory original;
  setUp(() async {
    original = DataDirectory.current;
    root = await Directory.systemTemp.createTemp('pi-managed-runtime-');
    DataDirectory.current = DataDirectory(root.path);
  });
  tearDown(() async {
    DataDirectory.current = original;
    await root.delete(recursive: true);
  });
  Future<File> fixture(String version, {String? actualVersion}) async {
    final directory = Directory(
      p.join(
        root.path,
        'pi-runtime',
        'releases',
        version,
        'node_modules',
        '@earendil-works',
        'pi-coding-agent',
      ),
    );
    await directory.create(recursive: true);
    await File(p.join(directory.path, 'package.json')).writeAsString(
      jsonEncode({
        'name': '@earendil-works/pi-coding-agent',
        'version': actualVersion ?? version,
      }),
    );
    final cli = File(p.join(directory.path, 'dist', 'bundle', 'cli.js'));
    await cli.parent.create(recursive: true);
    await cli.writeAsString('');
    await File(p.join(root.path, 'pi-runtime', 'current-version'))
        .writeAsString(version);
    return cli;
  }

  test(
    'uses a verified installed official release outside the app bundle',
    () async {
      final cli = await fixture('99.0.0');
      expect(await managedPiCli(), cli.path);
    },
  );
  test(
    'an incomplete installation never replaces the bundled runtime',
    () async {
      await fixture('99.0.0', actualVersion: '98.0.0');
      expect(await managedPiCli(), isNull);
      final cli = await fixture('99.0.0');
      await cli.delete();
      expect(await managedPiCli(), isNull);
    },
  );
  test(
    'rejects traversal pointers and older versions after a desktop upgrade',
    () async {
      await fixture('0.0.1');
      expect(await managedPiCli(), isNull);
      await File(p.join(root.path, 'pi-runtime', 'current-version'))
          .writeAsString('../unrelated');
      expect(await managedPiCli(), isNull);
    },
  );
}
