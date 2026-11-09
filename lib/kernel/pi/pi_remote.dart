import 'dart:async';
import 'dart:convert';

import 'package:pi_remote/client.dart';
import 'package:crypto/crypto.dart';

import '../../remote/remote_location.dart';
import '../../remote/ssh_host.dart';
import 'pi_transport.dart';

/// Remote paths refer to the host, never to the desktop's bundled runtime.
class RemotePiOptions {
  const RemotePiOptions({
    this.executable = 'pi',
    this.agentDirectory,
    this.extension,
    this.forwardLoopback = false,
  });
  final String executable;
  final String? agentDirectory;

  /// An extension already installed on the remote host. Desktop tools require
  /// an explicitly forwarded bridge and remote-aware path handling.
  final String? extension;

  /// Explicitly permit forwarding loopback URLs supplied in launch.environment.
  final bool forwardLoopback;
}

Future<PiTransport> startRemotePi(
  PiLaunch launch, {
  RemotePiOptions options = const RemotePiOptions(),
}) async {
  final name = RemoteLocation.hostOf(launch.cwd);
  if (name == null || name.isEmpty) {
    throw ArgumentError('Expected an SSH project location');
  }
  final host = SshHosts.instance[name];
  final client = await host.ready;
  final home = host.home;
  if (options.agentDirectory == null && (home == null || home.isEmpty)) {
    throw StateError('Remote host did not report a home directory');
  }
  return startRemotePiWithClient(
    launch,
    client,
    agentDirectory:
        options.agentDirectory ??
        host.paths.join(home!, '.pi-desktop', 'pi-agent'),
    options: options,
  );
}

/// Injectable entry point for a connected client and an absolute host-side directory.
Future<PiTransport> startRemotePiWithClient(
  PiLaunch launch,
  RemoteClient client, {
  required String agentDirectory,
  RemotePiOptions options = const RemotePiOptions(),
}) async {
  if (!RemoteLocation.isRemote(launch.cwd)) {
    throw ArgumentError('Expected an SSH project location');
  }
  final cwd = RemoteLocation.pathOf(launch.cwd);
  final paths = RemoteLocation.pathsFor(cwd);
  if (!paths.isAbsolute(agentDirectory)) {
    throw ArgumentError('Remote agent directory must be absolute');
  }
  final sessions = paths.join(
    agentDirectory,
    'sessions',
    sha256.convert(utf8.encode(paths.normalize(cwd))).toString(),
  );
  final environment = <String, String>{...launch.environment};
  final forwards = <RemoteForward>[];
  try {
    for (final entry in launch.environment.entries) {
      final uri = Uri.tryParse(entry.value);
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          !{'localhost', '127.0.0.1', '::1'}.contains(uri.host)) {
        continue;
      }
      if (!options.forwardLoopback || !uri.hasPort) {
        throw StateError(
          'Loopback URL in ${entry.key} requires explicit forwarding',
        );
      }
      final forward = await client.forward(uri.port);
      forwards.add(forward);
      environment[entry.key] = uri
          .replace(host: '127.0.0.1', port: forward.remotePort)
          .toString();
    }
    environment.addAll({
      'PI_CODING_AGENT_DIR': agentDirectory,
      'PI_CODING_AGENT_SESSION_DIR': sessions,
      'PI_SKIP_VERSION_CHECK': '1',
      'PI_DESKTOP_PERMISSION': launch.permission,
      'NO_COLOR': '1',
      'CLAUDECODE': '',
    });
    final args = <String>[
      '--mode',
      'rpc',
      '--no-approve',
      if (options.extension case final extension?) ...[
        '--extension',
        extension,
      ],
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
      if (launch.thinking case final thinking?) ...['--thinking', thinking],
      if (launch.tools case final tools?) ...[
        if (tools.isEmpty) '--no-tools' else ...['--tools', tools.join(',')],
      ],
      if (launch.instructions.isNotEmpty) ...[
        launch.ownPrompt ? '--system-prompt' : '--append-system-prompt',
        launch.instructions,
      ],
    ];
    final process = await client.start(
      options.executable,
      args,
      cwd: cwd,
      environment: environment,
    );
    return _RemotePiTransport(process, forwards);
  } catch (_) {
    for (final forward in forwards) {
      await forward.close();
    }
    rethrow;
  }
}

class _RemotePiTransport implements PiTransport {
  _RemotePiTransport(this.process, this.forwards) {
    output = _read();
    stderr = process.stderr.transform(utf8.decoder).listen((text) {
      diagnostic += text;
      if (diagnostic.length > 8192) {
        diagnostic = diagnostic.substring(diagnostic.length - 8192);
      }
    });
    done = _finish();
  }
  final RemoteProcess process;
  final List<RemoteForward> forwards;
  final controller = StreamController<Map<String, Object?>>();
  late final Future<void> output;
  late final StreamSubscription<String> stderr;
  late final Future<void> done;
  String diagnostic = '';
  bool closing = false;
  Timer? timer;
  @override
  Stream<Map<String, Object?>> get messages => controller.stream;
  @override
  Future<void> get exited => done;
  Future<void> _read() async {
    try {
      await for (final line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) controller.add(decoded);
      }
    } on Object catch (error) {
      if (!closing) {
        controller.addError(StateError('Invalid Pi RPC output: $error'));
      }
      close();
    }
  }

  Future<void> _finish() async {
    final code = await process.exitCode;
    await output;
    await stderr.cancel();
    timer?.cancel();
    for (final forward in forwards) {
      await forward.close();
    }
    controller.add({
      'type': 'transport_exit',
      'code': code,
      'stderr': diagnostic.trim(),
      'expected': closing,
    });
    unawaited(controller.close());
  }

  @override
  void write(Map<String, Object?> message) {
    if (closing) throw StateError('Pi has stopped');
    process.write(utf8.encode('${jsonEncode(message)}\n'));
  }

  @override
  void close() {
    if (closing) return;
    closing = true;
    unawaited(process.closeStdin().catchError((Object _) {}));
    timer = Timer(const Duration(seconds: 3), () => process.kill(force: true));
  }
}
