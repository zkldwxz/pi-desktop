import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/child_process_registry.dart';
import '../../platform/data_dir.dart';
import '../../remote/remote_location.dart';
import 'pi_storage.dart';
import 'pi_transport.dart';
import 'pi_runtime_paths_io.dart';
import 'pi_cli_io.dart' show piCliCommand, piEnvironment;
import 'pi_remote_ssh.dart' show startSshPi, stopRemotePiProcesses;

final _live = <_ProcessPiTransport>{};
ChildProcessRegistry? _registry;
ChildProcessRegistry get _children => _registry ??= ChildProcessRegistry(
  file: File(DataDirectory.current.processRegistryFile('pi')),
  recognizes: (command) =>
      command.contains('pi-coding-agent') && command.contains('--mode rpc'),
);

Future<void> reapPiProcesses() => _children.reaped;
Future<void> stopPiProcesses() async {
  final transports = _live.toList();
  for (final transport in transports) {
    transport.close();
  }
  await Future.wait([
    ...transports.map((transport) => transport.exited),
    stopRemotePiProcesses(),
  ]);
  await _children.flush();
}

Future<PiTransport> startPi(PiLaunch launch) async {
  if (RemoteLocation.isRemote(launch.cwd)) {
    return startSshPi(launch, forwardLoopback: true);
  }
  if (!await Directory(launch.cwd).exists()) {
    throw FileSystemException('Project folder does not exist', launch.cwd);
  }
  final runtime = await findPiRuntime();
  final extension = p.join(runtime.path, 'desktop-extension.mjs');
  final invocation = await piCliCommand();
  final agentDir = PiStorage.agentDirectory;
  final sessions = PiStorage.sessionsDirectory(launch.cwd);
  await Directory(agentDir).create(recursive: true);
  await Directory(sessions).create(recursive: true);
  await _children.reaped;
  final args = [
    ...invocation.prefix,
    '--mode',
    'rpc',
    '--no-approve',
    '--extension',
    extension,
    if (!launch.persist)
      '--no-session'
    else ...[
      '--session-dir',
      sessions,
      if (launch.sessionPath case final path?) ...[
        '--session',
        path,
      ] else ...[
        '--session-id',
        launch.sessionId,
      ],
    ],
    if (launch.model case final model?) ...[
      if (launch.provider case final provider?) ...['--provider', provider],
      '--model',
      model,
    ],
    if (launch.thinking case final level?) ...['--thinking', level],
    if (launch.tools case final tools?) ...[
      if (tools.isEmpty) '--no-tools' else ...['--tools', tools.join(',')],
    ],
    if (launch.instructions.isNotEmpty) ...[
      launch.ownPrompt ? '--system-prompt' : '--append-system-prompt',
      launch.instructions,
    ],
  ];
  final environment = {
    ...await piEnvironment(launch.environment),
    'PI_CODING_AGENT_SESSION_DIR': sessions,
    'PI_DESKTOP_PERMISSION': launch.permission,
  };
  // The inner coding agent has its own release lifecycle; the desktop ships a
  // pinned copy. Inherit neither a different agent dir nor pi-desktop's core setup.
  environment.remove('CLAUDECODE');
  final process = await Process.start(
    invocation.executable,
    args,
    workingDirectory: launch.cwd,
    environment: environment,
    includeParentEnvironment: false,
  );
  final transport = _ProcessPiTransport(process);
  _live.add(transport);
  await _children.add(process.pid);
  return transport;
}

class _ProcessPiTransport implements PiTransport {
  _ProcessPiTransport(this._process) {
    _stdout = _readOutput();
    _stderr = _process.stderr.transform(utf8.decoder).listen((text) {
      _diagnostic += text;
      if (_diagnostic.length > 8192) {
        _diagnostic = _diagnostic.substring(_diagnostic.length - 8192);
      }
    });
    _exited = _finish();
  }

  final Process _process;
  final _messages = StreamController<Map<String, Object?>>();
  late final Future<void> _stdout;
  late final StreamSubscription<String> _stderr;
  late final Future<void> _exited;
  String _diagnostic = '';
  bool _closing = false;
  Timer? _killTimer;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  @override
  Future<void> get exited => _exited;

  Future<void> _readOutput() async {
    // LineSplitter accepts LF/CRLF and preserves U+2028/U+2029 in JSON strings.
    try {
      await for (final line
          in _process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        final json = jsonDecode(line);
        if (json is Map<String, dynamic>) _messages.add(json);
      }
    } on Object catch (error) {
      if (!_closing) {
        _messages.addError(StateError('Invalid Pi RPC output: $error'));
      }
      close();
    }
  }

  Future<void> _finish() async {
    final code = await _process.exitCode;
    await _stdout;
    await _stderr.cancel();
    _killTimer?.cancel();
    _live.remove(this);
    await _children.remove(_process.pid);
    _messages.add({
      'type': 'transport_exit',
      'code': code,
      'stderr': _diagnostic.trim(),
      'expected': _closing,
    });
    unawaited(_messages.close());
  }

  @override
  void write(Map<String, Object?> message) {
    if (_closing) throw StateError('Pi has stopped');
    _process.stdin.writeln(jsonEncode(message));
  }

  @override
  void close() {
    if (_closing) return;
    _closing = true;
    // EOF requests orderly shutdown; kill only if it cannot finish.
    unawaited(_process.stdin.close().catchError((Object _) {}));
    _killTimer = Timer(const Duration(seconds: 3), () {
      _process.kill(ProcessSignal.sigkill);
    });
  }
}
