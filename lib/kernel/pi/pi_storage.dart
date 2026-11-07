import '../agent_kernel.dart';
import 'pi_storage_stub.dart'
    if (dart.library.io) 'pi_storage_io.dart'
    as platform;

/// Pi's own append-only session files, in this app's isolated data directory.
class PiStorage implements SessionCatalog {
  const PiStorage();

  static String get agentDirectory => platform.agentDirectory;
  static String sessionsDirectory(String cwd) =>
      platform.sessionsDirectory(cwd);

  @override
  Future<List<ProjectRecord>> projects() => platform.projects();
  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) =>
      platform.sessionsIn(cwd);
  @override
  Future<void> delete(String id) => platform.deleteSession(id);
}
