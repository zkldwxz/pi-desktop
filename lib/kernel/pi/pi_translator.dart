import 'dart:convert';

import '../../chat/chat_models.dart';
import '../kernel_event.dart';

/// Reconstruct Pi's delta-only RPC events. Completed messages are authoritative;
/// a tool's execution updates replace its card rather than duplicate it.
class PiTranslator {
  PiTranslator({required this.emit, required this.nextSeq});
  final void Function(KernelEvent) emit;
  final int Function() nextSeq;
  int _message = 0;
  int _notice = 0;
  final Map<int, String> _texts = {};
  final Map<int, DateTime> _thinkingAt = {};
  final Map<String, Map<String, Object?>> _tools = {};
  int inputTokens = 0;
  int outputTokens = 0;
  double cost = 0;

  void beginTurn() {
    inputTokens = 0;
    outputTokens = 0;
    cost = 0;
  }

  String _id(int index) => 'pi-message-$_message-$index';
  void notice(String text, {NoticeKind kind = NoticeKind.error}) {
    emit(
      ItemUpserted(nextSeq(), 'pi-notice-${++_notice}', NoticeItem(kind, text)),
    );
  }

  void handle(Map<String, Object?> event) {
    switch (event['type']) {
      case 'message_start':
        final message = _map(event['message']);
        if (message['role'] == 'assistant') {
          _message++;
          _texts.clear();
          _thinkingAt.clear();
        }
      case 'message_update':
        final update = _map(event['assistantMessageEvent']);
        final index = (update['contentIndex'] as num?)?.toInt() ?? 0;
        final type = update['type'];
        if (type == 'text_start' || type == 'thinking_start') {
          _startBlock(index, thinking: type == 'thinking_start');
        } else if (type == 'text_delta' || type == 'thinking_delta') {
          final delta = update['delta'] as String? ?? '';
          if (!_texts.containsKey(index)) {
            _startBlock(index, thinking: type == 'thinking_delta');
          }
          final text = _texts[index]!;
          emit(TextDelta(nextSeq(), _id(index), text.length, delta));
          _texts[index] = '$text$delta';
        } else if (type == 'text_end' || type == 'thinking_end') {
          _completeBlock(
            index,
            update['content'] as String? ?? _texts[index] ?? '',
            thinking: type == 'thinking_end',
          );
        } else if (type == 'toolcall_end') {
          final call = _map(update['toolCall']);
          _tool(
            call['id'] as String? ?? '',
            call['name'] as String? ?? '',
            _map(call['arguments']),
            status: ToolStatus.running,
          );
        }
      case 'message_end':
        message(_map(event['message']));
      case 'tool_execution_start':
        _tool(
          event['toolCallId'] as String? ?? '',
          event['toolName'] as String? ?? '',
          _map(event['args']),
          status: ToolStatus.running,
        );
      case 'tool_execution_update':
        final id = event['toolCallId'] as String? ?? '';
        _tool(
          id,
          event['toolName'] as String? ?? '',
          _map(event['args']),
          status: ToolStatus.running,
          result: event['partialResult'],
        );
      case 'tool_execution_end':
        final id = event['toolCallId'] as String? ?? '';
        _tool(
          id,
          event['toolName'] as String? ?? '',
          _tools[id] ?? {},
          status: event['isError'] == true
              ? ToolStatus.failed
              : ToolStatus.succeeded,
          result: event['result'],
        );
      case 'extension_error':
        notice(event['error'] as String? ?? 'Pi extension failed');
    }
  }

  void _startBlock(int index, {required bool thinking}) {
    _texts[index] = '';
    if (thinking) _thinkingAt[index] = DateTime.now();
    emit(
      ItemUpserted(
        nextSeq(),
        _id(index),
        thinking
            ? ThinkingItem(text: '', tokens: 0, startedAt: _thinkingAt[index])
            : const AssistantTextItem(''),
        streaming: true,
      ),
    );
  }

  void _completeBlock(int index, String text, {required bool thinking}) {
    final started = _thinkingAt[index];
    final item = thinking
        ? ThinkingItem(
            text: text,
            tokens: 0,
            seconds: started == null
                ? 0
                : DateTime.now().difference(started).inSeconds,
          )
        : AssistantTextItem(text);
    _texts[index] = text;
    emit(ItemUpserted(nextSeq(), _id(index), item));
    emit(ItemCompleted(nextSeq(), _id(index), item: item));
  }

  /// Full messages from message_end and get_messages share one path.
  void message(Map<String, Object?> message, {bool history = false}) {
    final role = message['role'];
    if (history) {
      _message++;
      _texts.clear();
      _thinkingAt.clear();
    }
    if (role == 'user') {
      if (!history) return; // The desktop already echoed its user turn.
      final timestamp = (message['timestamp'] as num?)?.toInt();
      emit(
        ItemUpserted(
          nextSeq(),
          'pi-history-user-$_message',
          UserMessageItem(
            text: contentText(message['content']),
            images: contentImages(message['content']),
            sentAt: timestamp == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(timestamp),
          ),
        ),
      );
    } else if (role == 'assistant') {
      final content = message['content'];
      if (content is List) {
        for (var i = 0; i < content.length; i++) {
          final block = _map(content[i]);
          switch (block['type']) {
            case 'text':
              _completeBlock(
                i,
                block['text'] as String? ?? '',
                thinking: false,
              );
            case 'thinking':
              _completeBlock(
                i,
                block['thinking'] as String? ?? '',
                thinking: true,
              );
            case 'toolCall':
              _tool(
                block['id'] as String? ?? '',
                block['name'] as String? ?? '',
                _map(block['arguments']),
                status: ToolStatus.running,
              );
          }
        }
      }
      if (!history) {
        final usage = _map(message['usage']);
        inputTokens +=
            _count(usage['input']) +
            _count(usage['cacheRead']) +
            _count(usage['cacheWrite']);
        outputTokens += _count(usage['output']);
        cost += (_map(usage['cost'])['total'] as num?)?.toDouble() ?? 0;
      }
      if (message['stopReason'] == 'error') {
        notice(message['errorMessage'] as String? ?? 'Pi request failed');
      }
    } else if (role == 'toolResult') {
      _tool(
        message['toolCallId'] as String? ?? '',
        message['toolName'] as String? ?? '',
        _tools[message['toolCallId']] ?? {},
        status: message['isError'] == true
            ? ToolStatus.failed
            : ToolStatus.succeeded,
        result: message,
      );
    } else if (role == 'custom' && message['display'] != false) {
      notice(contentText(message['content']), kind: NoticeKind.info);
    }
  }

  void completeStreaming() {
    for (final index in _texts.keys) {
      emit(ItemCompleted(nextSeq(), _id(index)));
    }
  }

  void _tool(
    String id,
    String name,
    Map<String, Object?> args, {
    required ToolStatus status,
    Object? result,
  }) {
    if (id.isEmpty) return;
    if (args.isNotEmpty) {
      _tools[id] = args;
    } else {
      args = _tools[id] ?? args;
    }
    final path = (args['path'] ?? args['file_path']) as String?;
    final item = ToolCallItem(
      kind: switch (name) {
        'read' => ToolKind.read,
        'grep' || 'find' => ToolKind.search,
        'ls' => ToolKind.listDir,
        'write' || 'edit' => ToolKind.edit,
        'bash' || 'powershell' => ToolKind.command,
        _ => name.startsWith('mcp__') ? ToolKind.mcp : ToolKind.other,
      },
      target: path ?? (args['command'] as String?) ?? name,
      tool: name,
      callId: id,
      path: path,
      input: args,
      status: status,
      output: result == null ? null : contentText(_map(result)['content']),
      images: result == null
          ? const []
          : contentImages(_map(result)['content']),
    );
    emit(ItemUpserted(nextSeq(), 'pi-tool-$id', item));
  }

  static String contentText(Object? content) => content is String
      ? content
      : content is List
      ? [
          for (final block in content)
            if (block is Map && block['type'] == 'text')
              block['text'] as String? ?? '',
        ].join('\n')
      : '';

  static List<ImageAttachment> contentImages(Object? content) {
    final result = <ImageAttachment>[];
    if (content is! List) return result;
    for (final block in content) {
      if (block is! Map || block['type'] != 'image') continue;
      try {
        if (block['data'] case final String data) {
          result.add(
            ImageAttachment(
              bytes: base64Decode(data),
              mediaType: block['mimeType'] as String? ?? 'image/png',
            ),
          );
        }
      } on FormatException {
        /* Keep the rest of a damaged historical message. */
      }
    }
    return result;
  }

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? value.cast<String, Object?>() : const {};
  static int _count(Object? value) => value is num ? value.toInt() : 0;
}
