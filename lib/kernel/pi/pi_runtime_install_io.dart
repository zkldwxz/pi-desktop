import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';
import 'pi_node_io.dart';
import 'pi_runtime_install.dart';
import 'pi_runtime_paths_io.dart';
import 'pi_runtime_updates_io.dart' show managedPiCli;
import 'pi_transport.dart' show PiRuntimeSettings;

/// Whether a Pi can already be run.
Future<bool> piInstalled(Directory runtime) async =>
    PiRuntimeSettings.cliPath() != null ||
    Platform.environment['PI_DESKTOP_PI_CLI'] != null ||
    await managedPiCli() != null ||
    await bundledPiCli(runtime) != null;

Future<void> installPiRuntime(PiRuntimeInstall state) async {
  final runtime = await findPiRuntime();
  if (await piInstalled(runtime)) return;
  final node = await _node(state, runtime);
  state.report(PiSetupStage.pi);
  // npm, and what npm runs, find the node that runs them.
  final directory = p.dirname(node);
  final environment = {
    ...piNodeEnvironment(node, Platform.environment),
    for (final cli in [
      p.join(directory, 'node_modules', 'npm', 'bin', 'npm-cli.js'),
      p.join(
        directory,
        '..',
        'lib',
        'node_modules',
        'npm',
        'bin',
        'npm-cli.js',
      ),
    ])
      if (File(cli).existsSync()) 'PI_DESKTOP_NPM_CLI': p.normalize(cli),
  };
  final process = await Process.start(
    node,
    [
      p.join(runtime.path, 'runtime-manager.mjs'),
      'install',
      p.join(DataDirectory.current.path, 'pi-runtime'),
    ],
    workingDirectory: runtime.path,
    environment: environment,
  );
  final output = utf8.decoder.bind(process.stdout).join();
  var diagnostic = '';
  final errors = process.stderr.transform(utf8.decoder).listen((text) {
    diagnostic = '$diagnostic$text';
    if (diagnostic.length > 4096) {
      diagnostic = diagnostic.substring(diagnostic.length - 4096);
    }
  });
  try {
    final code = await process.exitCode.timeout(const Duration(minutes: 10));
    await output;
    if (code != 0) {
      throw StateError(
        diagnostic.trim().isEmpty
            ? 'Installing Pi failed ($code)'
            : 'Installing Pi failed: ${diagnostic.trim()}',
      );
    }
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    throw StateError('Installing Pi took too long: is the network up?');
  } finally {
    await errors.cancel();
  }
  if (!await piInstalled(runtime)) {
    throw StateError('Pi was installed, but cannot be found.');
  }
}

/// The Node.js to run Pi and npm with: one set, one downloaded before, one of
/// the machine's; else one downloaded now.
Future<String> _node(PiRuntimeInstall state, Directory runtime) async {
  final found = await piNodeExecutable(runtime);
  if (found != 'node' || await _runs(found)) return found;
  final target = piNodeTarget();
  if (target == null) {
    throw StateError(
      'There is no Node.js to download for this computer: install Node.js 22.19 or newer.',
    );
  }
  return _download(state, target);
}

Future<bool> _runs(String node) async {
  try {
    final result = await Process.run(node, const ['--version']);
    return result.exitCode == 0 && piNodeVersionOk('${result.stdout}');
  } on Object {
    return false;
  }
}

Future<String> _download(
  PiRuntimeInstall state,
  ({String os, String arch}) target,
) async {
  state.report(PiSetupStage.node, fraction: 0);
  final root = Directory(piNodeFolder())..createSync(recursive: true);
  final base = piNodeBase(target);
  final archiveName = piNodeArchive(target);
  final stage = Directory(p.join(root.path, 'download-$pid'));
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final uri = Uri.https('nodejs.org', '/dist/v$piNodeVersion');
    Future<HttpClientResponse> get(String name) async {
      final request = await client.getUrl(
        uri.replace(path: '${uri.path}/$name'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException(
          'nodejs.org answered ${response.statusCode} for $name',
        );
      }
      return response;
    }

    final sums = await utf8.decoder.bind(await get('SHASUMS256.txt')).join();
    final expected = piNodeChecksum(sums, archiveName);
    if (expected == null) {
      throw StateError('nodejs.org gives no checksum for $archiveName.');
    }
    final archive = File(p.join(stage.path, archiveName));
    final response = await get(archiveName);
    final total = response.contentLength;
    var received = 0;
    final sink = archive.openWrite();
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          state.report(PiSetupStage.node, fraction: received / total);
        }
      }
    } finally {
      await sink.close();
    }
    final digest = await sha256.bind(archive.openRead()).first;
    if ('$digest' != expected) {
      throw StateError(
        'The Node.js download is not what nodejs.org published.',
      );
    }
    // tar unpacks tarballs everywhere, and zips on Windows.
    final unpacked = await Process.run('tar', [
      '-xf',
      archive.path,
      '-C',
      stage.path,
    ]);
    if (unpacked.exitCode != 0) {
      throw StateError('Unpacking Node.js failed: ${unpacked.stderr}');
    }
    final destination = Directory(p.join(root.path, base));
    if (destination.existsSync()) destination.deleteSync(recursive: true);
    Directory(p.join(stage.path, base)).renameSync(destination.path);
    final program = piNodeProgram(destination.path, target);
    if (!await _runs(program)) {
      throw StateError('The Node.js that was downloaded does not run here.');
    }
    return program;
  } finally {
    client.close(force: true);
    if (stage.existsSync()) stage.deleteSync(recursive: true);
  }
}
