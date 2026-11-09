import 'pi_cli.dart';

bool get canRunPiCommands => false;

Future<PiCommandResult> runPiCommand(
  List<String> arguments, {
  String? cwd,
  required Duration timeout,
}) => throw UnsupportedError('No processes on the web');
