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
import 'package:pi_desktop/settings/pages/models_page.dart'
    show testModelThroughPi;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'switching away from an empty Pi chat keeps its session identity',
    () async {
      final oldData = DataDirectory.current;
      final root = await Directory.systemTemp.createTemp('pi-chat-switch-');
      DataDirectory.current = DataDirectory(p.join(root.path, 'data'));
      final providers = ModelProviders.memory(
        providers: const [
          ModelProvider(
            id: 'switch-test',
            name: 'Local test',
            protocol: ProviderProtocol.openaiChat,
            baseUrl: 'http://127.0.0.1:1/v1',
            models: [
              ProviderModel(id: 'test-model', efforts: ['none']),
            ],
          ),
        ],
      );
      final kernel = PiKernel(
        KernelRegistry.pi,
        KernelContext(cwd: root.path),
        providers: providers,
      );
      final id = kernel.sessionId;
      try {
        for (var i = 0; i < 3; i++) {
          kernel.prepare();
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (kernel.health.status == KernelHealthStatus.idle ||
              kernel.health.status == KernelHealthStatus.starting) {
            if (DateTime.now().isAfter(deadline)) fail('Pi startup timed out');
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(
            kernel.health.status,
            KernelHealthStatus.ready,
            reason: kernel.health.message,
          );
          expect(kernel.sessionId, id, reason: 'reopened $i times');
          kernel.release();
          await kernel.stopped;
        }
      } finally {
        kernel.dispose();
        await kernel.stopped;
        providers.dispose();
        DataDirectory.current = oldData;
        await root.delete(recursive: true);
      }
    },
  );

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
      final sessionId = kernel.sessionId;
      final userEvents = events
          .whereType<ItemUpserted>()
          .where((event) => event.item is UserMessageItem)
          .length;
      kernel.release();
      await kernel.stopped;
      final reopened = kernel.events.firstWhere(
        (_) =>
            kernel.health.status == KernelHealthStatus.ready ||
            kernel.health.status == KernelHealthStatus.failed,
      );
      kernel.prepare();
      await reopened.timeout(const Duration(seconds: 15));
      await Future<void>.delayed(Duration.zero);
      expect(kernel.health.status, KernelHealthStatus.ready);
      expect(kernel.sessionId, sessionId);
      expect(
        events.whereType<ItemUpserted>().where(
          (event) => event.item is UserMessageItem,
        ),
        hasLength(userEvents),
        reason: 'switching back must not replay messages already on screen',
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

  test('an empty saved conversation follows added and edited upstreams through real Pi', () async {
    final oldData = DataDirectory.current;
    final oldProviders = ModelProviders.current;
    final oldLedger = UsageLedger.current;
    final root = await Directory.systemTemp.createTemp('pi-upstream-edit-');
    DataDirectory.current = DataDirectory(p.join(root.path, 'data'));
    UsageLedger.current = UsageLedger(MemoryUsageStorage());
    final providers = ModelProviders.memory();
    ModelProviders.current = providers;
    final received = <({String endpoint, String model, String? key})>[];
    final failures = <Object>[];
    Future<HttpServer> endpoint(String name) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        try {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(request.uri.path, '/v1/chat/completions');
          received.add((
            endpoint: name,
            model: body['model'] as String,
            key: request.headers.value('authorization'),
          ));
          request.response.headers.set('content-type', 'text/event-stream');
          for (final choice in [
            {
              'index': 0,
              'delta': {'content': 'Answer from $name'},
              'finish_reason': null,
            },
            {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
          ]) {
            request.response.write(
              'data: ${jsonEncode({
                'id': name,
                'object': 'chat.completion.chunk',
                'created': 1,
                'model': body['model'],
                'choices': [choice],
              })}\n\n',
            );
          }
          request.response.write('data: [DONE]\n\n');
        } catch (error) {
          failures.add(error);
        }
        await request.response.close();
      });
      return server;
    }

    final first = await endpoint('first');
    final second = await endpoint('second');
    final kernel = PiKernel(
      KernelRegistry.pi,
      KernelContext(
        cwd: root.path,
        settings: const {'model': '@anthropic/claude-opus-4-8'},
      ),
      providers: providers,
      hostTools: false,
    );
    final events = <KernelEvent>[];
    final listener = kernel.events.listen(events.add);
    Future<void> turn(String id) async {
      final ended = kernel.events
          .where((event) => event is TurnEnded && event.turnId == id)
          .first;
      kernel.send(KernelTurn(id: id, text: 'Reply briefly.'));
      await ended.timeout(const Duration(seconds: 25));
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
    }

    try {
      kernel.prepare();
      await pumpEventQueue();
      expect(kernel.health.noModel, true);
      expect(kernel.model.selected, isNull);
      await providers.save(
        ModelProvider(
          id: 'mine',
          name: 'Mine',
          protocol: ProviderProtocol.openaiChat,
          baseUrl: 'http://127.0.0.1:${first.port}/v1',
          models: const [
            ProviderModel(id: 'model-a', efforts: ['none']),
          ],
        ),
      );
      await providers.setKey('mine', 'fixture-first');
      await turn('one');
      final session = kernel.sessionId;
      expect(kernel.model.selected, '@mine/model-a');
      expect(received.single, (
        endpoint: 'first',
        model: 'model-a',
        key: 'Bearer fixture-first',
      ));

      await providers.save(
        providers
            .provider('mine')!
            .copyWith(
              baseUrl: 'http://127.0.0.1:${second.port}/v1',
              models: const [
                ProviderModel(id: 'model-b', efforts: ['none']),
              ],
            ),
      );
      await providers.setKey('mine', 'fixture-second');
      await turn('two');
      expect(kernel.sessionId, session);
      expect(kernel.model.selected, '@mine/model-b');
      expect(received, [
        (endpoint: 'first', model: 'model-a', key: 'Bearer fixture-first'),
        (endpoint: 'second', model: 'model-b', key: 'Bearer fixture-second'),
      ]);
      expect(failures, isEmpty);

      // Settings' test button must test its supplied snapshot, including a
      // disabled model, rather than the conversation's current default.
      final answer = await testModelThroughPi(
        providers
            .provider('mine')!
            .copyWith(baseUrl: 'http://127.0.0.1:${first.port}/v1'),
        const ProviderModel(
          id: 'disabled-test',
          enabled: false,
          efforts: ['none'],
        ),
      );
      expect(answer.text, 'Answer from first');
      expect(received.last, (
        endpoint: 'first',
        model: 'disabled-test',
        key: 'Bearer fixture-second',
      ));
    } finally {
      kernel.dispose();
      await kernel.stopped;
      await listener.cancel();
      providers.dispose();
      await first.close(force: true);
      await second.close(force: true);
      UsageLedger.current.flush();
      UsageLedger.current = oldLedger;
      ModelProviders.current = oldProviders;
      DataDirectory.current = oldData;
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
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
