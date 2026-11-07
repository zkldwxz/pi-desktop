import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pi_desktop/chat/chat_models.dart';
import 'package:pi_desktop/kernel/agent_kernel.dart';
import 'package:pi_desktop/kernel/claude_code/claude_sdk_tools.dart';
import 'package:pi_desktop/kernel/kernel_event.dart';
import 'package:pi_desktop/kernel/kernel_registry.dart';
import 'package:pi_desktop/kernel/kernel_types.dart';
import 'package:pi_desktop/kernel/pi/pi_kernel.dart';
import 'package:pi_desktop/kernel/pi/pi_storage.dart';
import 'package:pi_desktop/models/model_provider.dart';
import 'package:pi_desktop/models/model_providers.dart';
import 'package:pi_desktop/platform/data_dir.dart';
import 'package:pi_desktop/usage/usage_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('real Pi edits through desktop approval, streams its answer, and resumes its own history', () async {
    final oldData = DataDirectory.current;
    final oldLedger = UsageLedger.current;
    final usageStorage = MemoryUsageStorage();
    UsageLedger.current = UsageLedger(usageStorage);
    final root = await Directory.systemTemp.createTemp(
      'pi-desktop-integration-',
    );
    final project = await Directory(p.join(root.path, 'project')).create();
    DataDirectory.current = DataDirectory(p.join(root.path, 'data'));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    final failures = <Object>[];
    var desktopCalls = 0;
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'desktop_echo_fixture',
        description: 'Exercise the desktop bridge',
        inputSchema: const {
          'type': 'object',
          'properties': <String, Object?>{},
        },
        run: (input, call) async {
          desktopCalls++;
          return 'desktop pong';
        },
      ),
    );
    server.listen((request) async {
      try {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(request.uri.path, '/v1/chat/completions');
        expect(request.headers.value('authorization'), 'Bearer test-key');
        expect(body['model'], 'desktop-test-model');
        requests++;
        final toolCall = requests <= 2;
        request.response.headers.set('content-type', 'text/event-stream');
        final delta = toolCall
            ? {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call-$requests',
                    'type': 'function',
                    'function': {
                      'name': requests == 1
                          ? 'write'
                          : 'mcp__pi_desktop__desktop_echo_fixture',
                      'arguments': jsonEncode(
                        requests == 1
                            ? {
                                'path': 'hello.txt',
                                'content': 'written by real Pi',
                              }
                            : <String, Object?>{},
                      ),
                    },
                  },
                ],
              }
            : {'content': 'Finished from Pi.'};
        request.response.write(
          'data: ${jsonEncode({
            'id': 'chat-$requests',
            'object': 'chat.completion.chunk',
            'created': 1,
            'model': 'desktop-test-model',
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': null},
            ],
          })}\n\n',
        );
        request.response.write(
          'data: ${jsonEncode({
            'id': 'chat-$requests',
            'object': 'chat.completion.chunk',
            'created': 1,
            'model': 'desktop-test-model',
            'choices': [
              {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': toolCall ? 'tool_calls' : 'stop'},
            ],
            'usage': {'prompt_tokens': 100, 'completion_tokens': 10, 'total_tokens': 110},
          })}\n\ndata: [DONE]\n\n',
        );
      } on Object catch (error) {
        failures.add(error);
      }
      await request.response.close();
    });
    final providers = ModelProviders.memory(
      providers: [
        ModelProvider(
          id: 'integration',
          name: 'Local test',
          protocol: ProviderProtocol.openaiChat,
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          models: const [
            ProviderModel(id: 'desktop-test-model', efforts: ['none']),
          ],
        ),
      ],
    );
    await providers.setKey('integration', 'test-key');
    final kernel = PiKernel(
      KernelRegistry.pi,
      KernelContext(cwd: project.path),
      providers: providers,
    );
    final edits = _Edits();
    kernel.editWatch = edits;
    final events = <KernelEvent>[];
    final ended = Completer<void>();
    var approvals = 0;
    final listener = kernel.events.listen((event) {
      events.add(event);
      if (event is InteractionRequested) {
        approvals++;
        scheduleMicrotask(
          () => kernel.answer(
            event.request.id,
            const ApprovalAnswer(ApprovalDecision.allowOnce),
          ),
        );
      }
      if (event is TurnEnded && !ended.isCompleted) ended.complete();
    });
    PiKernel? resumed;
    StreamSubscription<KernelEvent>? replayListener;
    try {
      kernel.send(
        const KernelTurn(
          id: 'edit-turn',
          text: 'Create hello.txt and confirm when finished.',
        ),
      );
      await ended.future.timeout(const Duration(seconds: 35));
      expect(failures, isEmpty);
      expect(
        kernel.health.status,
        KernelHealthStatus.ready,
        reason: events
            .whereType<ItemUpserted>()
            .map((event) => event.item)
            .whereType<NoticeItem>()
            .map((notice) => notice.text)
            .join('\n'),
      );
      expect(requests, 3);
      expect(desktopCalls, 1);
      UsageLedger.current.flush();
      final calls = await usageStorage.read(await usageStorage.days());
      expect(calls, hasLength(3));
      expect(
        calls.every(
          (call) =>
              call.provider == 'integration' &&
              call.session == kernel.sessionId,
        ),
        true,
      );
      expect(calls.last.output, 10);
      expect(approvals, 2);
      expect(
        await File(p.join(project.path, 'hello.txt')).readAsString(),
        'written by real Pi',
      );
      expect(edits.before, [p.join(project.path, 'hello.txt')]);
      expect(edits.after, [p.join(project.path, 'hello.txt')]);
      expect(
        events
            .whereType<ItemUpserted>()
            .map((event) => event.item)
            .whereType<AssistantTextItem>()
            .last
            .text,
        'Finished from Pi.',
      );
      kernel.dispose();
      await kernel.stopped;
      final sessions = await const PiStorage().sessionsIn(project.path);
      expect(sessions, hasLength(1));
      expect(
        p.isWithin(DataDirectory.current.path, sessions.single.path!),
        true,
      );
      resumed = PiKernel(
        KernelRegistry.pi,
        KernelContext(cwd: project.path, resume: sessions.single),
        providers: providers,
      );
      final replayed = <KernelEvent>[];
      replayListener = resumed.events.listen(replayed.add);
      resumed.prepare();
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (resumed.health.status == KernelHealthStatus.idle ||
          resumed.health.status == KernelHealthStatus.starting) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Pi history restore timed out');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(resumed.health.status, KernelHealthStatus.ready);
      expect(
        replayed
            .whereType<ItemUpserted>()
            .map((event) => event.item)
            .whereType<UserMessageItem>()
            .first
            .text,
        'Create hello.txt and confirm when finished.',
      );
      expect(
        replayed
            .whereType<ItemUpserted>()
            .map((event) => event.item)
            .whereType<AssistantTextItem>()
            .last
            .text,
        'Finished from Pi.',
      );
    } finally {
      resumed?.dispose();
      await resumed?.stopped;
      await replayListener?.cancel();
      kernel.dispose();
      await kernel.stopped;
      await listener.cancel();
      ClaudeSdkTools.unregister('desktop_echo_fixture');
      providers.dispose();
      await server.close(force: true);
      UsageLedger.current.flush();
      UsageLedger.current = oldLedger;
      DataDirectory.current = oldData;
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}

class _Edits implements EditWatch {
  final before = <String>[];
  final after = <String>[];
  @override
  Future<void> beforeEdit(String path) async {
    before.add(path);
  }

  @override
  Future<void> afterEdit(String path) async {
    after.add(path);
  }
}
