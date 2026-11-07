import 'pi_runtime_updates.dart';

Future<PiRuntimeUpdateInfo> piRuntimeCommand(String command) => Future.error(
  UnsupportedError('Pi runtime updates require the desktop app'),
);
