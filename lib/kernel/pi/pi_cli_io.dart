import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'pi_cli.dart' show PiCommandResult;
import 'pi_runtime_paths_io.dart';
import 'pi_runtime_updates_io.dart' show managedPiCli;
import 'pi_storage.dart';
import 'pi_transport.dart' show PiRuntimeSettings;

bool get canRunPiCommands => true;

/// What starts the Pi in use: the program, and what comes before Pi's own
/// arguments (the script, when Pi is run by Node).
Future<({String executable, List<String> prefix})> piCliCommand() async {
  final runtime = await findPiRuntime();
  final cli =
      PiRuntimeSettings.cliPath() ??
      Platform.environment['PI_DESKTOP_PI_CLI'] ??
      await managedPiCli() ??
      p.join(
        runtime.path,
        'node_modules',
        '@earendil-works',
        'pi-coding-agent',
        'dist',
        'bundle',
        'cli.js',
      );
  if (cli.endsWith('.js') || cli.endsWith('.mjs')) {
    return (executable: await piNodeExecutable(runtime), prefix: [cli]);
  }
  return (executable: cli, prefix: const <String>[]);
}

/// The environment Pi runs in: pi-desktop's own agent folder, and none of
/// the update checks that would reach for the network on their own.
Map<String, String> piEnvironment(Map<String, String> extra) => {
  ...Platform.environment,
  ...extra,
  'PI_CODING_AGENT_DIR': PiStorage.agentDirectory,
  'PI_SKIP_VERSION_CHECK': '1',
  'NO_COLOR': '1',
};

Future<PiCommandResult> runPiCommand(
  List<String> arguments, {
  String? cwd,
  required Duration timeout,
}) async {
  final invocation = await piCliCommand();
  await Directory(PiStorage.agentDirectory).create(recursive: true);
  final process = await Process.start(
    invocation.executable,
    [...invocation.prefix, ...arguments],
    workingDirectory: cwd,
    environment: piEnvironment(const {}),
    includeParentEnvironment: false,
  );
  final out = utf8.decoder.bind(process.stdout).join();
  final err = utf8.decoder.bind(process.stderr).join();
  try {
    final code = await process.exitCode.timeout(timeout);
    return PiCommandResult(code, await out, await err);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    throw StateError('pi ${arguments.join(' ')} timed out');
  }
}
