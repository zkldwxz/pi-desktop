import '../agent_kernel.dart';

String get agentDirectory => '';
String sessionsDirectory(String cwd) => '';
Future<List<ProjectRecord>> projects() async => const [];
Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];
Future<void> deleteSession(String id) async {}
