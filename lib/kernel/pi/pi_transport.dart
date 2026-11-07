import 'pi_transport_stub.dart'
    if (dart.library.io) 'pi_transport_io.dart'
    as platform;

/// The pinned Pi coding agent's public JSONL RPC protocol.
abstract interface class PiTransport {
  Stream<Map<String, Object?>> get messages;
  void write(Map<String, Object?> message);
  void close();
  Future<void> get exited;
}

class PiLaunch {
  const PiLaunch({
    required this.cwd,
    required this.sessionId,
    this.sessionPath,
    this.provider,
    this.model,
    this.thinking,
    this.permission = 'ask',
    this.instructions = '',
    this.ownPrompt = false,
    this.persist = true,
    this.tools,
    this.environment = const {},
  });

  final String cwd;
  final String sessionId;
  final String? sessionPath;
  final String? provider;
  final String? model;
  final String? thinking;
  final String permission;
  final String instructions;
  final bool ownPrompt;
  final bool persist;
  final List<String>? tools;
  final Map<String, String> environment;
}

typedef PiTransportFactory = Future<PiTransport> Function(PiLaunch launch);

abstract final class PiRuntimeSettings {
  static const pathKey = 'pi.path';
  static const nodeKey = 'pi.nodePath';
  static String? Function() cliPath = () => null;
  static String? Function() nodePath = () => null;
}

Future<PiTransport> startPi(PiLaunch launch) => platform.startPi(launch);
Future<void> stopPiProcesses() => platform.stopPiProcesses();
Future<void> reapPiProcesses() => platform.reapPiProcesses();
