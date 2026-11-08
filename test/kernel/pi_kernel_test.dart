import 'dart:async';

import 'package:pi_desktop/chat/chat_models.dart';
import 'package:pi_desktop/kernel/agent_kernel.dart';
import 'package:pi_desktop/kernel/kernel_event.dart';
import 'package:pi_desktop/kernel/kernel_types.dart';
import 'package:pi_desktop/kernel/pi/pi_kernel.dart';
import 'package:pi_desktop/kernel/pi/pi_providers.dart';
import 'package:pi_desktop/kernel/pi/pi_transport.dart';
import 'package:pi_desktop/models/model_providers.dart';
import 'package:pi_desktop/models/model_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakePi transport;
  late PiKernel kernel;
  late List<KernelEvent> events;
  late StreamSubscription<KernelEvent> subscription;
  late ModelProviders providers;
  late List<_FakePi> launches;

  Future<void> ready({
    SessionRecord? resume,
    Completer<PiTransport>? startGate,
    ModelProviders? configured,
    Map<String, String> settings = const {},
    KernelHealthStatus? expectedHealth,
    Future<PiProviderSetup> Function(ModelProviders)? configure,
  }) async {
    transport = _FakePi();
    launches = [];
    providers =
        configured ??
        ModelProviders.memory(
          providers: const [
            ModelProvider(
              id: 'test',
              name: 'My upstream',
              models: [
                ProviderModel(id: 'model-a'),
                ProviderModel(id: 'model-b'),
              ],
            ),
          ],
        );
    final descriptor = KernelDescriptor(
      id: 'pi',
      label: 'PI',
      icon: Icons.auto_awesome,
      description: 'Pi',
      create: (_) => throw UnimplementedError(),
    );
    kernel = PiKernel(
      descriptor,
      KernelContext(cwd: '/project', resume: resume, settings: settings),
      start: (launch) async {
        if (launches.isNotEmpty) transport = _FakePi();
        transport.launch = launch;
        transport.model = launch.model ?? 'model-a';
        launches.add(transport);
        return startGate == null ? transport : await startGate.future;
      },
      providers: providers,
      configureProviders:
          configure ??
          (_) async => const PiProviderSetup({}, [
            PiModelBinding(
              ref: '@test/model-a',
              provider: 'test',
              model: 'model-a',
            ),
            PiModelBinding(
              ref: '@test/model-b',
              provider: 'test',
              model: 'model-b',
            ),
          ]),
      hostTools: false,
    );
    events = [];
    subscription = kernel.events.listen(events.add);
    kernel.prepare();
    await pumpEventQueue();
    expect(
      kernel.health.status,
      expectedHealth ??
          (startGate == null
              ? KernelHealthStatus.ready
              : KernelHealthStatus.starting),
    );
  }

  tearDown(() async {
    kernel.dispose();
    await kernel.stopped;
    await subscription.cancel();
  });

  test(
    'disposing during startup waits for and closes the pending Pi process',
    () async {
      final gate = Completer<PiTransport>();
      await ready(startGate: gate);
      kernel.dispose();
      var stopped = false;
      final stopping = kernel.stopped.then((_) => stopped = true);
      await pumpEventQueue();
      expect(stopped, false);
      gate.complete(transport);
      await stopping;
      expect(stopped, true);
      expect(transport.writes, isEmpty);
    },
  );

  test(
    'uses Pi model/thinking RPC and restores authoritative choices',
    () async {
      await ready();
      expect(kernel.descriptor.id, 'pi');
      expect(kernel.model.selected, '@test/model-a');
      kernel.model.select('@test/model-b');
      await pumpEventQueue();
      expect(
        transport.writes
            .where((message) => message['type'] == 'set_model')
            .single,
        containsPair('modelId', 'model-b'),
      );
      expect(kernel.model.selected, '@test/model-b');
      kernel.effort.select('@test/model-b', 'high');
      await pumpEventQueue();
      expect(kernel.effort.selected, 'high');
    },
  );

  test(
    'translates streaming text and tools, ending only at agent_settled',
    () async {
      await ready();
      kernel.send(const KernelTurn(id: 'turn-1', text: 'hello'));
      await pumpEventQueue();
      transport.add({
        'type': 'message_start',
        'message': {'role': 'assistant'},
      });
      transport.add({
        'type': 'message_update',
        'assistantMessageEvent': {
          'type': 'text_delta',
          'contentIndex': 0,
          'delta': 'hello world',
        },
      });
      transport.add({
        'type': 'message_end',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'hello world'},
          ],
          'usage': {
            'input': 10,
            'output': 2,
            'cacheRead': 20,
            'cost': {'total': 0.1},
          },
        },
      });
      transport.add({
        'type': 'tool_execution_start',
        'toolCallId': 'call-1',
        'toolName': 'read',
        'args': {'path': 'a.dart'},
      });
      transport.add({
        'type': 'tool_execution_end',
        'toolCallId': 'call-1',
        'toolName': 'read',
        'result': {
          'content': [
            {'type': 'text', 'text': 'file data'},
          ],
        },
        'isError': false,
      });
      transport.add({'type': 'agent_end'});
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>(), isEmpty);
      expect(events.whereType<TextDelta>().single.text, 'hello world');
      final tool = events
          .whereType<ItemUpserted>()
          .map((event) => event.item)
          .whereType<ToolCallItem>()
          .last;
      expect(tool.status, ToolStatus.succeeded);
      expect(tool.output, 'file data');
      transport.add({'type': 'agent_settled', 'aborted': false});
      await pumpEventQueue();
      final ended = events.whereType<TurnEnded>().single;
      expect(ended.turnId, 'turn-1');
      expect(ended.usage!.inputTokens, 30);
      expect(ended.usage!.costUsd, 0.1);
    },
  );

  test('queues messages once, preserves session, and starts the next after settlement', () async {
    await ready();
    kernel.send(const KernelTurn(id: 'a', text: 'first'));
    kernel.send(const KernelTurn(id: 'b', text: 'second'));
    kernel.send(const KernelTurn(id: 'b', text: 'duplicate'));
    await pumpEventQueue();
    expect(
      transport.writes.where((message) => message['type'] == 'prompt'),
      hasLength(1),
    );
    transport.add({'type': 'agent_settled'});
    await pumpEventQueue();
    expect(
      transport.writes
          .where((message) => message['type'] == 'prompt')
          .map((message) => message['message']),
      ['first', 'second'],
    );
    expect(events.whereType<TurnStarted>().map((event) => event.turnId), [
      'a',
      'b',
    ]);
    expect(kernel.sessionId, 'pi-session');
  });

  test(
    'extension confirmations are answered once and cancel aborts the Pi run',
    () async {
      await ready();
      kernel.send(const KernelTurn(id: 'a', text: 'work'));
      await pumpEventQueue();
      transport.add({
        'type': 'extension_ui_request',
        'id': 'approval',
        'method': 'confirm',
        'title': 'Allow bash?',
        'message': 'pwd',
      });
      await pumpEventQueue();
      expect(
        events.whereType<InteractionRequested>().single.request,
        isA<ApprovalRequest>(),
      );
      kernel.answer('approval', const ApprovalAnswer(ApprovalDecision.deny));
      kernel.answer(
        'approval',
        const ApprovalAnswer(ApprovalDecision.allowOnce),
      );
      expect(
        transport.writes
            .where((message) => message['type'] == 'extension_ui_response')
            .single['confirmed'],
        false,
      );
      kernel.cancel();
      await pumpEventQueue();
      expect(
        transport.writes.any((message) => message['type'] == 'abort'),
        true,
      );
      transport.add({'type': 'agent_settled', 'aborted': true});
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().single.interrupted, true);
    },
  );

  test(
    'a handled extension command completes without waiting for an agent run',
    () async {
      await ready();
      transport.handled = true;
      kernel.send(const KernelTurn(id: 'command', text: '/example'));
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().single.turnId, 'command');
    },
  );

  test(
    'empty configuration never launches a built-in Anthropic model',
    () async {
      await ready(
        configured: ModelProviders.memory(),
        expectedHealth: KernelHealthStatus.failed,
      );
      expect(launches, isEmpty);
      expect(kernel.health.noModel, true);
      expect(kernel.model.options, isEmpty);
      expect(kernel.model.selected, isNull);
    },
  );

  test(
    'saved native model falls back to the enabled desktop upstream',
    () async {
      await ready(settings: const {'model': '@anthropic/claude-opus-4-8'});
      expect(transport.launch!.provider, 'test');
      expect(transport.launch!.model, 'model-a');
      expect(kernel.model.selected, '@test/model-a');
      expect(kernel.model.options.map((option) => option.id), [
        '@test/model-a',
        '@test/model-b',
      ]);
      expect(kernel.model.options.first.group!.label, 'My upstream');
    },
  );

  test(
    'adding an upstream repairs an already opened empty conversation',
    () async {
      await ready(
        configured: ModelProviders.memory(),
        expectedHealth: KernelHealthStatus.failed,
      );
      await providers.save(
        const ModelProvider(
          id: 'test',
          name: 'Mine',
          models: [ProviderModel(id: 'model-a')],
        ),
      );
      expect(kernel.model.selected, '@test/model-a');
      kernel.prepare();
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.ready);
      expect(launches.single.launch!.model, 'model-a');
    },
  );

  test(
    'disabled and removed selections use an enabled default model',
    () async {
      final configured = ModelProviders.memory(
        providers: const [
          ModelProvider(
            id: 'test',
            name: 'Mine',
            models: [
              ProviderModel(id: 'model-a'),
              ProviderModel(id: 'model-b', enabled: false),
            ],
          ),
        ],
      );
      await configured.setDefaultModel('@test/missing');
      await ready(
        configured: configured,
        settings: const {'model': '@test/model-b'},
      );
      expect(kernel.model.selected, '@test/model-a');
      expect(kernel.model.options.map((option) => option.id), [
        '@test/model-a',
      ]);
    },
  );

  test(
    'provider edits apply before queued prompts without losing the session',
    () async {
      await ready(
        configure: (providers) async => PiProviderSetup(
          {'endpoint': providers.provider('test')!.baseUrl},
          const [
            PiModelBinding(
              ref: '@test/model-a',
              provider: 'test',
              model: 'model-a',
            ),
            PiModelBinding(
              ref: '@test/model-b',
              provider: 'test',
              model: 'model-b',
            ),
          ],
        ),
      );
      kernel.send(const KernelTurn(id: 'first', text: 'first'));
      kernel.send(const KernelTurn(id: 'second', text: 'second'));
      await pumpEventQueue();
      final previous = transport;
      await providers.save(
        providers.provider('test')!.copyWith(baseUrl: 'https://new.example/v1'),
      );
      expect(launches, hasLength(1));
      previous.add({'type': 'agent_settled'});
      await pumpEventQueue();
      expect(launches, hasLength(2));
      expect(
        transport.launch!.environment['endpoint'],
        'https://new.example/v1',
      );
      expect(transport.launch!.sessionPath, '/own/pi-session.jsonl');
      expect(
        transport.writes
            .where((message) => message['type'] == 'prompt')
            .single['message'],
        'second',
      );
    },
  );

  test(
    'provider edits during configuration discard the obsolete launch',
    () async {
      final gate = Completer<PiProviderSetup>();
      var calls = 0;
      await ready(
        expectedHealth: KernelHealthStatus.starting,
        configure: (providers) async {
          calls++;
          if (calls == 1) return gate.future;
          return PiProviderSetup(
            {'endpoint': providers.provider('test')!.baseUrl},
            const [
              PiModelBinding(
                ref: '@test/model-a',
                provider: 'test',
                model: 'model-a',
              ),
            ],
          );
        },
      );
      await providers.save(
        providers
            .provider('test')!
            .copyWith(baseUrl: 'https://latest.example/v1'),
      );
      gate.complete(const PiProviderSetup({'endpoint': 'obsolete'}, []));
      await pumpEventQueue();
      expect(launches, hasLength(1));
      expect(
        transport.launch!.environment['endpoint'],
        'https://latest.example/v1',
      );
      expect(kernel.health.status, KernelHealthStatus.ready);
    },
  );

  test('loads history through Pi RPC and resumes its session file', () async {
    await ready(
      resume: SessionRecord(
        id: 'pi-session',
        title: 'kept',
        updatedAt: DateTime(2026),
        cwd: '/project',
        path: '/own/pi-session.jsonl',
      ),
    );
    expect(transport.launch!.sessionPath, '/own/pi-session.jsonl');
    expect(
      events
          .whereType<ItemUpserted>()
          .map((event) => event.item)
          .whereType<UserMessageItem>()
          .single
          .text,
      'past question',
    );
    expect(
      events
          .whereType<ItemUpserted>()
          .map((event) => event.item)
          .whereType<AssistantTextItem>()
          .last
          .text,
      'past answer',
    );
    expect(kernel.loadingHistory, false);
  });
}

class _FakePi implements PiTransport {
  final _messages = StreamController<Map<String, Object?>>();
  final _exited = Completer<void>();
  final writes = <Map<String, Object?>>[];
  PiLaunch? launch;
  bool handled = false;
  String model = 'model-a';
  String thinking = 'medium';
  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  @override
  Future<void> get exited => _exited.future;
  Map<String, Object?> get modelInfo => {
    'id': model,
    'provider': 'test',
    'name': model,
    'contextWindow': 128000,
  };
  void add(Map<String, Object?> event) => _messages.add(event);
  @override
  void write(Map<String, Object?> message) {
    writes.add(message);
    final type = message['type'];
    if (type == 'extension_ui_response') return;
    Object data = {};
    switch (type) {
      case 'get_state':
        data = {
          'sessionId': 'pi-session',
          'sessionFile': '/own/pi-session.jsonl',
          'model': modelInfo,
          'thinkingLevel': thinking,
        };
      case 'get_available_models':
        data = {
          'models': [
            modelInfo,
            {...modelInfo, 'id': 'model-b', 'name': 'model-b'},
            {
              'provider': 'anthropic',
              'id': 'claude-opus-4-8',
              'name': 'Built-in Claude',
            },
          ],
        };
      case 'get_available_thinking_levels':
        data = {
          'levels': ['off', 'medium', 'high'],
        };
      case 'get_commands':
        data = {'commands': []};
      case 'get_messages':
        data = {
          'messages': [
            {'role': 'user', 'content': 'past question'},
            {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'past answer'},
              ],
            },
          ],
        };
      case 'get_session_stats':
        data = {
          'cost': 0.1,
          'contextUsage': {'tokens': 30, 'contextWindow': 128000},
        };
      case 'prompt':
        data = {'disposition': handled ? 'handled' : 'started'};
      case 'set_model':
        model = message['modelId'] as String;
        data = modelInfo;
      case 'set_thinking_level':
        thinking = message['level'] as String;
    }
    scheduleMicrotask(
      () => add({
        'id': message['id'],
        'type': 'response',
        'success': true,
        'data': data,
      }),
    );
  }

  @override
  void close() {
    if (_exited.isCompleted) return;
    _exited.complete();
    unawaited(_messages.close());
  }
}
