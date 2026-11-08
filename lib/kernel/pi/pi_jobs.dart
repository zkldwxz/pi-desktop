import 'dart:async';
import 'dart:convert';

import '../../chat/chat_models.dart';
import '../../models/model_providers.dart';
import '../../platform/data_dir.dart';
import '../../usage/usage_record.dart' show UsageClass;
import 'pi_kernel.dart' show newPiSessionId;
import 'pi_providers.dart';
import 'pi_translator.dart';
import 'pi_transport.dart';
import 'pi_usage.dart';

class PiJobAnswer {
  const PiJobAnswer(
    this.text,
    this.firstText,
    this.lastText,
    this.outputTokens,
  );
  final String text;
  final Duration firstText;
  final Duration lastText;
  final int? outputTokens;
}

class PiJobCancelled implements Exception {
  const PiJobCancelled();
}

/// Small jobs (titles, commit messages, composer actions) use the same Pi
/// runtime as conversations, with no saved session and a restricted tool set.
Future<PiJobAnswer> askPi({
  required String system,
  required String prompt,
  String? model,
  String? cwd,
  Future<void>? cancel,
  List<ImageAttachment> images = const [],
  List<String> tools = const [],
  int maxTurns = 12,
  ModelProviders? providers,
}) async {
  final configured = providers ?? ModelProviders.current;
  final ref = configured.configuredModel(model);
  if (ref == null) {
    throw StateError('Enable a model in Settings → Models to start Pi.');
  }
  final setup = await piProviderSetup(configured);
  final custom = setup.bindings
      .where((binding) => binding.ref == ref)
      .firstOrNull;
  if (custom == null) {
    throw StateError('The selected upstream model is no longer available.');
  }
  final transport = await startPi(
    PiLaunch(
      cwd: cwd ?? DataDirectory.current.path,
      sessionId: newPiSessionId(),
      persist: false,
      provider: custom.provider,
      model: custom.model,
      thinking: 'off',
      ownPrompt: true,
      instructions: system,
      permission: 'full',
      tools: [
        for (final tool in tools)
          switch (tool) {
            'Read' => 'read',
            'Grep' => 'grep',
            'Glob' => 'find',
            _ => tool.toLowerCase(),
          },
      ],
      environment: setup.environment,
    ),
  );
  final result = Completer<PiJobAnswer>();
  final watch = Stopwatch()..start();
  final started = DateTime.now();
  Duration? first;
  Duration? last;
  var text = '';
  var turns = 0;
  int? tokens;
  late final StreamSubscription<Map<String, Object?>> subscription;
  void fail(Object error) {
    if (!result.isCompleted) result.completeError(error);
  }

  subscription = transport.messages.listen((event) {
    final type = event['type'];
    if (type == 'message_update' && event['assistantMessageEvent'] is Map) {
      final update = event['assistantMessageEvent'] as Map;
      if (update['type'] == 'text_delta') {
        first ??= watch.elapsed;
        last = watch.elapsed;
      }
    } else if (type == 'message_end' && event['message'] is Map) {
      final message = event['message'] as Map;
      if (message['role'] == 'assistant') {
        recordPiUsage(
          message.cast<String, Object?>(),
          providers: configured,
          modelRef: ref,
          started: started,
          duration: watch.elapsed,
          firstToken: first,
          requestClass: UsageClass.auxiliary,
        );
        turns++;
        if (message['stopReason'] == 'error') {
          fail(
            StateError(
              message['errorMessage'] as String? ?? 'Pi request failed',
            ),
          );
        } else {
          final answer = PiTranslator.contentText(message['content']);
          if (answer.isNotEmpty) text = answer;
          final usage = message['usage'];
          if (usage is Map) {
            tokens = (tokens ?? 0) + ((usage['output'] as num?)?.toInt() ?? 0);
          }
          if (turns > maxTurns) {
            fail(StateError('Pi exceeded the job turn limit'));
          }
        }
      }
    } else if (type == 'response' && event['success'] == false) {
      fail(StateError(event['error'] as String? ?? 'Pi request failed'));
    } else if (type == 'agent_settled' && !result.isCompleted) {
      if (text.isEmpty) {
        fail(StateError('Pi returned no answer'));
      } else {
        result.complete(
          PiJobAnswer(
            text,
            first ?? watch.elapsed,
            last ?? watch.elapsed,
            tokens,
          ),
        );
      }
    } else if (type == 'transport_exit') {
      fail(StateError('Pi exited before answering. ${event['stderr'] ?? ''}'));
    }
  }, onError: fail);
  if (cancel != null) {
    unawaited(
      cancel.then((_) {
        if (!result.isCompleted) {
          fail(const PiJobCancelled());
          transport.close();
        }
      }),
    );
  }
  try {
    transport.write({
      'id': 'desktop-job',
      'type': 'prompt',
      'message': prompt,
      if (images.isNotEmpty)
        'images': [
          for (final image in images)
            {
              'type': 'image',
              'data': base64Encode(image.bytes),
              'mimeType': image.mediaType,
            },
        ],
    });
    return await result.future.timeout(const Duration(minutes: 3));
  } finally {
    await subscription.cancel();
    transport.close();
    await transport.exited;
  }
}
