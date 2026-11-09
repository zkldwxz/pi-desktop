import 'pi_cli_stub.dart' if (dart.library.io) 'pi_cli_io.dart' as platform;

/// What a `pi` command line printed and how it ended.
class PiCommandResult {
  const PiCommandResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// The words that say why it failed: what it wrote to stderr, else to
  /// stdout.
  String get failure {
    final text = stderr.trim().isEmpty ? stdout.trim() : stderr.trim();
    return text.isEmpty ? 'pi exited with code $exitCode' : text;
  }
}

/// Runs the bundled Pi with [arguments] (`install npm:pkg`, `remove …`) in
/// pi-desktop's agent folder, in [cwd] when given; throws when it cannot be
/// started or is not done within [timeout].
Future<PiCommandResult> runPiCommand(
  List<String> arguments, {
  String? cwd,
  Duration timeout = const Duration(minutes: 5),
}) => platform.runPiCommand(arguments, cwd: cwd, timeout: timeout);

/// Whether commands can be run here (not on the web).
bool get canRunPiCommands => platform.canRunPiCommands;
