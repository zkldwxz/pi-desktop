import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/client.dart' show SshLauncher, SshTarget, findSsh;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../remote/remote_location.dart';
import 'pi_runtime_paths_io.dart';
import 'pi_transport.dart';

final _active = <_SshPi>{};

/// Stop all direct SSH PI processes during application shutdown.
Future<void> stopRemotePiProcesses() async {
  final active = _active.toList();
  for (final process in active) {
    process.close();
  }
  await Future.wait(active.map((process) => process.exited));
}

/// Starts the host's installed PI without requiring a remote desktop server.
/// Loopback URLs in the environment are forwarded only with explicit consent.
Future<PiTransport> startSshPi(
  PiLaunch launch, {
  String executable = 'pi',
  String? agentDirectory,
  bool forwardLoopback = false,
}) async {
  final host = RemoteLocation.hostOf(launch.cwd);
  if (host == null || !SshTarget.isValid(host)) {
    throw ArgumentError('Invalid SSH project host');
  }
  final target = SshTarget.parse(host);
  if (target.wslDistro != null) {
    throw UnsupportedError('Direct PI SSH does not support WSL');
  }
  final runtime = await findPiRuntime();
  final extension = await File(p.join(runtime.path, 'desktop-extension.mjs'))
      .readAsString();
  final config = await File(p.join(runtime.path, 'desktop-config.mjs'))
      .readAsString();
  final env = <String, String>{...launch.environment};
  final forwards = <int, int>{};
  Future<String> rewrite(String value, String name) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        !{'localhost', '127.0.0.1', '::1'}.contains(uri.host)) {
      return value;
    }
    if (!forwardLoopback || !uri.hasPort) {
      throw StateError('Loopback URL in $name requires explicit forwarding');
    }
    final remote = forwards[uri.port] ??= await _availablePort();
    return uri.replace(host: '127.0.0.1', port: remote).toString();
  }

  for (final entry in launch.environment.entries) {
    if (entry.key == 'PI_DESKTOP_PROVIDERS') {
      final providers = jsonDecode(entry.value);
      if (providers is! List) {
        throw const FormatException('Invalid PI providers');
      }
      for (final provider in providers) {
        if (provider is Map && provider['baseUrl'] is String) {
          provider['baseUrl'] = await rewrite(
            provider['baseUrl'] as String,
            entry.key,
          );
        }
      }
      env[entry.key] = jsonEncode(providers);
    } else {
      env[entry.key] = await rewrite(entry.value, entry.key);
    }
  }
  final cwd = RemoteLocation.pathOf(launch.cwd);
  final args = <String>[
    '--mode',
    'rpc',
    '--no-approve',
    if (!launch.persist)
      '--no-session'
    else ...[
      '--session-dir',
      '__SESSIONS__',
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
  final encoded = base64.encode(utf8.encode(_bootstrap));
  final command =
      'node -e "eval(Buffer.from(\'$encoded\',\'base64\').toString())"';
  final process = await Process.start(findSsh(Platform.environment) ?? 'ssh', [
    ...SshLauncher.defaultOptions,
    if (forwards.isNotEmpty) ...['-o', 'ExitOnForwardFailure=yes'],
    for (final entry in forwards.entries) ...[
      '-R',
      '127.0.0.1:${entry.value}:127.0.0.1:${entry.key}',
    ],
    ...target.arguments,
    command,
  ]);
  final transport = _SshPi(process);
  _active.add(transport);
  process.stdin.writeln(
    jsonEncode({
      'cwd': cwd,
      'agentDirectory': agentDirectory,
      'executable': executable,
      'args': args,
      'environment': {
        ...env,
        'PI_SKIP_VERSION_CHECK': '1',
        'PI_DESKTOP_PERMISSION': launch.permission,
        'NO_COLOR': '1',
        'CLAUDECODE': '',
      },
      'extension': extension,
      'config': config,
      'version': sha256.convert(utf8.encode(extension + config)).toString(),
    }),
  );
  return transport;
}

Future<int> _availablePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

// Only fixed code is placed on the command line. All user data arrives via stdin.
const _bootstrap = r'''
const fs = require('fs'), os = require('os'), path = require('path'), cp = require('child_process');
let pending = Buffer.alloc(0), child;
process.stdin.on('data', chunk => {
  if (child) { child.stdin.write(chunk); return; }
  pending = Buffer.concat([pending, chunk]);
  const end = pending.indexOf(10); if (end < 0) return;
  try {
    const o = JSON.parse(pending.subarray(0,end).toString());
    const agent = o.agentDirectory || path.join(os.homedir(), '.pi-desktop', 'pi-agent');
    const sessions = path.join(agent, 'sessions', require('crypto').createHash('sha256').update(path.normalize(o.cwd)).digest('hex'));
    const bridge = o.agentDirectory ? path.join(agent, 'bridge', o.version) : path.join(os.homedir(), '.pi-desktop', 'bridge', o.version);
    fs.mkdirSync(sessions, {recursive:true, mode:0o700});
    fs.mkdirSync(bridge, {recursive:true, mode:0o700});
    fs.writeFileSync(path.join(bridge, 'desktop-extension.mjs'), o.extension, {mode:0o600});
    fs.writeFileSync(path.join(bridge, 'desktop-config.mjs'), o.config, {mode:0o600});
    const args = o.args.map(x => x === '__SESSIONS__' ? sessions : x);
    args.push('--extension', path.join(bridge, 'desktop-extension.mjs'));
    child = cp.spawn(o.executable, args, {cwd:o.cwd, env:{...process.env, ...o.environment, PI_CODING_AGENT_DIR:agent, PI_CODING_AGENT_SESSION_DIR:sessions}, stdio:['pipe','pipe','pipe']});
    child.stdout.pipe(process.stdout); child.stderr.pipe(process.stderr);
    child.on('error', e => { console.error('Could not start remote Pi. Install pi and ensure it is on PATH: ' + e.message); process.exitCode = 127; process.stdin.destroy(); });
    child.on('exit', (code, signal) => { process.exitCode = code ?? 1; process.stdin.destroy(); });
    if (pending.length > end+1) child.stdin.write(pending.subarray(end+1));
    pending = null;
  } catch (e) { console.error('Remote Pi bootstrap failed: ' + e.message); process.exitCode = 1; process.stdin.destroy(); }
});
process.stdin.on('end', () => { if (child) child.stdin.end(); });
''';

class _SshPi implements PiTransport {
  _SshPi(this.process) {
    output = _read();
    stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((text) {
          diagnostic += text;
          if (diagnostic.length > 8192) {
            diagnostic = diagnostic.substring(diagnostic.length - 8192);
          }
        });
    done = _finish();
  }
  final Process process;
  final controller = StreamController<Map<String, Object?>>();
  late final Future<void> output, done;
  late final StreamSubscription<String> stderr;
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
        final value = jsonDecode(line);
        if (value is Map<String, dynamic>) controller.add(value);
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
    _active.remove(this);
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
    process.stdin.writeln(jsonEncode(message));
  }

  @override
  void close() {
    if (closing) return;
    closing = true;
    unawaited(process.stdin.close().catchError((Object _) {}));
    timer = Timer(
      const Duration(seconds: 3),
      () => process.kill(ProcessSignal.sigkill),
    );
  }
}
