import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pi_desktop/kernel/pi/pi_cli_io.dart';
import 'package:pi_desktop/kernel/pi/pi_runtime_paths_io.dart';
import 'package:pi_desktop/kernel/pi/pi_transport.dart';
import 'package:pi_desktop/platform/data_dir.dart';

void main() {
  group('Pi subprocess Node environment', () {
    late Directory root;
    late DataDirectory original;
    late String? Function() cliPath;
    late String? Function() nodePath;
    late String bin;

    setUp(() async {
      original = DataDirectory.current;
      cliPath = PiRuntimeSettings.cliPath;
      nodePath = PiRuntimeSettings.nodePath;
      final node = await piNodeExecutable(await findPiRuntime());
      root = await Directory.systemTemp.createTemp('pi-node-environment-');
      DataDirectory.current = DataDirectory(p.join(root.path, 'data'));
      bin = p.join(root.path, 'node', 'bin');
      await Directory(bin).create(recursive: true);
      final executable = File(p.join(bin, 'node'));
      await executable.writeAsString('#!/bin/sh\nexec "$node" "\$@"\n');
      final npm = File(p.join(bin, 'npm'));
      await npm.writeAsString('#!/bin/sh\nprintf "selected-node-npm\\n"\n');
      for (final file in [executable, npm]) {
        final result = await Process.run('chmod', ['755', file.path]);
        expect(result.exitCode, 0);
      }
      final cli = File(p.join(root.path, 'cli.js'));
      await cli.writeAsString('''
const { spawnSync } = require('node:child_process');
const result = spawnSync('npm', ['--version'], { encoding: 'utf8' });
console.log(JSON.stringify({
  type: 'node_environment',
  npm: result.stdout?.trim(),
  error: result.error?.code,
  path: process.env.PATH,
  extra: process.env.PI_ENV_TEST,
  agent: process.env.PI_CODING_AGENT_DIR,
}));
''');
      PiRuntimeSettings.cliPath = () => cli.path;
      PiRuntimeSettings.nodePath = () => executable.path;
    });

    tearDown(() async {
      await stopPiProcesses();
      PiRuntimeSettings.cliPath = cliPath;
      PiRuntimeSettings.nodePath = nodePath;
      DataDirectory.current = original;
      await root.delete(recursive: true);
    });

    test('prepends selected Node to an explicitly supplied PATH', () async {
      final environment = await piEnvironment({
        'PATH': '/usr/bin:/bin',
        'PI_ENV_TEST': 'kept',
      });
      expect(environment['PATH'], '$bin:/usr/bin:/bin');
      expect(environment['PI_ENV_TEST'], 'kept');
      expect(environment['PI_SKIP_VERSION_CHECK'], '1');
    });

    test('CLI commands find npm belonging to the selected Node', () async {
      final result = await runPiCommand(
        const [],
        timeout: const Duration(seconds: 10),
      );
      expect(result.exitCode, 0, reason: result.stderr);
      final output = jsonDecode(result.stdout) as Map;
      expect(output['npm'], 'selected-node-npm');
      expect(output['path'], startsWith('$bin:'));
      expect(output['agent'], startsWith(DataDirectory.current.path));
    });

    test('RPC sessions find npm even with no system Node on PATH', () async {
      final transport = await startPi(
        PiLaunch(
          cwd: root.path,
          sessionId: 'node-environment',
          persist: false,
          environment: const {'PATH': '/usr/bin:/bin', 'PI_ENV_TEST': 'kept'},
        ),
      );
      final messages = await transport.messages.toList().timeout(
        const Duration(seconds: 10),
      );
      await transport.exited;
      final output = messages.first;
      expect(output['type'], 'node_environment');
      expect(output['npm'], 'selected-node-npm');
      expect(output['error'], isNull);
      expect(output['path'], '$bin:/usr/bin:/bin');
      expect(output['extra'], 'kept');
    });
  }, skip: Platform.isWindows);
}
