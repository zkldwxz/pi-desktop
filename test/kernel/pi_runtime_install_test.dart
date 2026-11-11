import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:pi_desktop/kernel/pi/pi_node_io.dart';
import 'package:pi_desktop/kernel/pi/pi_runtime_install.dart';

void main() {
  group('the Node.js Pi runs on', () {
    test('is 22.19 or newer', () {
      for (final ok in ['v22.19.0', 'v22.23.4\n', 'v24.11.1', 'v23.0.0']) {
        expect(piNodeVersionOk(ok), isTrue, reason: ok);
      }
      for (final no in [
        'v22.18.9',
        'v20.11.0',
        'v18.0.0',
        '',
        'node',
        '22.19.0',
      ]) {
        expect(piNodeVersionOk(no), isFalse, reason: no);
      }
    });

    test('is the build for this computer, in the archive nodejs.org keeps', () {
      final mac = piNodeTarget(Abi.macosArm64)!;
      expect(piNodeBase(mac), 'node-v$piNodeVersion-darwin-arm64');
      expect(piNodeArchive(mac), 'node-v$piNodeVersion-darwin-arm64.tar.gz');
      expect(
        piNodeArchive(piNodeTarget(Abi.linuxX64)!),
        'node-v$piNodeVersion-linux-x64.tar.gz',
      );
      final windows = piNodeTarget(Abi.windowsX64)!;
      expect(piNodeArchive(windows), 'node-v$piNodeVersion-win-x64.zip');
      expect(piNodeProgram(r'C:\n', windows), contains('node.exe'));
      expect(piNodeProgram('/n', mac), '/n/bin/node');
      expect(piNodeTarget(Abi.androidArm64), isNull);
    });

    test(
      'is checked against the checksum nodejs.org publishes for its file',
      () {
        final digest = 'ab' * 32;
        final sums =
            '${'cd' * 32}  node-v1-linux-x64.tar.gz\n'
            '$digest  node-v1-darwin-arm64.tar.gz\n';
        expect(piNodeChecksum(sums, 'node-v1-darwin-arm64.tar.gz'), digest);
        expect(piNodeChecksum(sums, 'node-v1-win-x64.zip'), isNull);
        // Twice, or not a digest: not taken.
        expect(
          piNodeChecksum(
            '$sums$digest  node-v1-darwin-arm64.tar.gz\n',
            'node-v1-darwin-arm64.tar.gz',
          ),
          isNull,
        );
        expect(piNodeChecksum('zz  file.zip\n', 'file.zip'), isNull);
      },
    );
  });

  group('Node subprocess PATH', () {
    test('keeps other variables and prepends the selected Node directory', () {
      final bin = p.join(Directory.current.path, 'downloaded-node', 'bin');
      final pathKey = Platform.isWindows ? 'Path' : 'PATH';
      final separator = Platform.isWindows ? ';' : ':';
      final original = {pathKey: 'existing', 'OTHER': 'kept'};
      final environment = piNodeEnvironment(p.join(bin, 'node'), original);
      expect(environment[pathKey], '$bin${separator}existing');
      expect(environment['OTHER'], 'kept');
      expect(original, {pathKey: 'existing', 'OTHER': 'kept'});
      if (Platform.isWindows) expect(environment.containsKey('PATH'), isFalse);
    });

    test('does not add the working directory for a bare node command', () {
      expect(piNodeEnvironment('node', const {'PATH': 'kept'}), {
        'PATH': 'kept',
      });
    });

    test('a missing or empty PATH has no empty search entry', () {
      final bin = p.join(Directory.current.path, 'downloaded-node', 'bin');
      for (final environment in [
        <String, String>{},
        {'PATH': ''},
      ]) {
        expect(
          piNodeEnvironment(p.join(bin, 'node'), environment)['PATH'],
          bin,
        );
      }
    });
  });

  group('setting Pi up', () {
    late Future<void> Function(PiRuntimeInstall) saved;
    setUp(() => saved = PiRuntimeInstall.installer);
    tearDown(() => PiRuntimeInstall.installer = saved);

    test('is done once at a time, its stages shown, then idle', () async {
      final install = PiRuntimeInstall();
      final gate = Completer<void>();
      var runs = 0;
      PiRuntimeInstall.installer = (state) async {
        runs++;
        state.report(PiSetupStage.node, fraction: .5);
        await gate.future;
        state.report(PiSetupStage.pi);
      };
      final stages = <PiSetupStage>[];
      install.addListener(() => stages.add(install.stage));
      final first = install.ensure();
      final second = install.ensure();
      await Future<void>.delayed(Duration.zero);
      expect(install.busy, isTrue);
      expect(install.stage, PiSetupStage.node);
      expect(install.fraction, .5);
      gate.complete();
      await Future.wait([first, second]);
      expect(runs, 1);
      expect(stages, [PiSetupStage.node, PiSetupStage.pi, PiSetupStage.idle]);
      expect(install.busy, isFalse);
    });

    test('says why it failed, and is tried again when asked again', () async {
      final install = PiRuntimeInstall();
      var attempts = 0;
      PiRuntimeInstall.installer = (state) async {
        if (++attempts == 1) {
          throw StateError('npm could not reach the registry');
        }
      };
      await expectLater(install.ensure(), throwsStateError);
      expect(install.stage, PiSetupStage.failed);
      expect(install.error, 'npm could not reach the registry');
      await install.ensure();
      expect(install.stage, PiSetupStage.idle);
      expect(install.error, isNull);
      expect(attempts, 2);
    });
  });
}
