import '../claude_code/claude_sdk_tools.dart';
import '../agent_kernel.dart' show EditWatch;
import 'pi_host_tools_stub.dart'
    if (dart.library.io) 'pi_host_tools_io.dart'
    as platform;

abstract interface class PiHostBridge {
  Map<String, String> get environment;
  Future<void> close();
}

Future<PiHostBridge?> startPiHostTools({
  required String cwd,
  required String sessionId,
  required ClaudeSdkAsk ask,
  required Future<void>? Function() cancelled,
  required EditWatch? Function() editWatch,
}) => platform.startPiHostTools(
  cwd: cwd,
  sessionId: sessionId,
  ask: ask,
  cancelled: cancelled,
  editWatch: editWatch,
);
