import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';
import '../agent_kernel.dart';

String get agentDirectory => p.join(DataDirectory.current.path, 'pi-agent');
String get _sessionsRoot => p.join(agentDirectory, 'sessions');
String _canonical(String cwd) {
  String path;
  try {
    path = Directory(cwd).resolveSymbolicLinksSync();
  } on FileSystemException {
    path = p.normalize(p.absolute(cwd));
  }
  return Platform.isWindows ? path.toLowerCase() : path;
}

String sessionsDirectory(String cwd) => p.join(
  _sessionsRoot,
  sha256.convert(utf8.encode(_canonical(cwd))).toString(),
);

Stream<File> _files(Directory directory) async* {
  if (!await directory.exists()) return;
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File && entity.path.endsWith('.jsonl')) yield entity;
  }
}

Future<SessionRecord?> _record(File file) async {
  String? id;
  String? cwd;
  String? title;
  var named = false;
  try {
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (decoded is! Map) continue;
      if (decoded['type'] == 'session') {
        id = decoded['id'] as String?;
        cwd = decoded['cwd'] as String?;
      } else if (decoded['type'] == 'session_info' &&
          decoded['name'] is String) {
        title = decoded['name'] as String;
        named = true;
      } else if (!named && title == null && decoded['type'] == 'message') {
        final message = decoded['message'];
        if (message is Map && message['role'] == 'user') {
          final content = message['content'];
          title = content is String
              ? content
              : content is List
              ? [
                  for (final block in content)
                    if (block is Map && block['type'] == 'text') block['text'],
                ].join('\n')
              : '';
        }
      }
    }
    if (id == null || cwd == null) return null;
    final text = (title ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return SessionRecord(
      id: id,
      title: text.length > 160 ? '${text.substring(0, 157)}...' : text,
      updatedAt: await file.lastModified(),
      cwd: cwd,
      path: file.path,
    );
  } on FileSystemException {
    return null;
  }
}

Future<List<ProjectRecord>> projects() async {
  final grouped = <String, List<SessionRecord>>{};
  await for (final file in _files(Directory(_sessionsRoot))) {
    if (await _record(file) case final record?) {
      (grouped[record.cwd] ??= []).add(record);
    }
  }
  final result = [
    for (final MapEntry(key: cwd, value: sessions) in grouped.entries)
      ProjectRecord(
        path: cwd,
        sessions: sessions..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
      ),
  ];
  result.sort((a, b) => b.updatedAt!.compareTo(a.updatedAt!));
  return result;
}

Future<List<SessionRecord>> sessionsIn(String cwd) async {
  final records = <SessionRecord>[];
  await for (final file in _files(Directory(sessionsDirectory(cwd)))) {
    if (await _record(file) case final record?
        when p.equals(_canonical(record.cwd), _canonical(cwd))) {
      records.add(record);
    }
  }
  records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return records;
}

Future<void> deleteSession(String id) async {
  await for (final file in _files(Directory(_sessionsRoot))) {
    if ((await _record(file))?.id == id) await file.delete();
  }
}
