import 'dart:convert';
import 'dart:io';

import '../kernel/pi/pi_storage.dart';
import '../kernel/pi/pi_translator.dart';
import 'conversation_search.dart';

/// Index this fork's Pi conversations without opening Claude Code's store.
class PiConversationSearch implements ConversationSearch {
  final _text = <String, ({DateTime modified, String text})>{};
  List<String> _recent = const [];

  @override
  Future<void> prepare() async {
    final projects = await const PiStorage().projects();
    final sessions = projects.expand((project) => project.sessions).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _recent = [for (final session in sessions) session.id];
    _text.removeWhere((id, _) => !_recent.contains(id));
    for (final session in sessions) {
      if (_text[session.id]?.modified == session.updatedAt ||
          session.path == null) {
        continue;
      }
      final text = StringBuffer();
      try {
        await for (final line in File(
          session.path!,
        ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
          try {
            final entry = jsonDecode(line);
            if (entry is! Map || entry['type'] != 'message') continue;
            final message = entry['message'];
            if (message is Map &&
                const {'user', 'assistant'}.contains(message['role'])) {
              text.writeln(PiTranslator.contentText(message['content']));
            }
          } on FormatException {
            /* An incomplete last line can be retried later. */
          }
        }
        _text[session.id] = (
          modified: session.updatedAt,
          text: text.toString(),
        );
      } on FileSystemException {
        /* A concurrently removed session is skipped. */
      }
    }
  }

  @override
  Future<List<ConversationHit>> search(String query, {int limit = 50}) async {
    if (query.trim().isEmpty || limit <= 0) return const [];
    final hits = <ConversationHit>[];
    for (final id in _recent) {
      final text = _text[id]?.text;
      if (text == null) continue;
      final hit = findIn(id, text, query);
      if (hit != null) hits.add(hit);
      if (hits.length >= limit) break;
    }
    return hits;
  }
}
