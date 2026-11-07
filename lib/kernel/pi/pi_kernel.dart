import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../../models/model_provider.dart';
import '../../models/model_providers.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'pi_host_tools.dart';
import 'pi_providers.dart';
import 'pi_translator.dart';
import 'pi_transport.dart';
import 'pi_usage.dart';

/// The desktop's Pi adapter. All model work and tool execution belongs to the
/// official pinned Pi process; this class translates its public RPC protocol.
class PiKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsPermission,
        SelectsEffort,
        ProvidesCommands,
        ReportsContext,
        QueuesMessages,
        RenamesSession,
        AcceptsImages,
        LoadsHistory,
        WatchesEdits {
  PiKernel(
    this.descriptor,
    this._context, {
    this._start = startPi,
    ModelProviders? providers,
    Future<PiProviderSetup> Function(ModelProviders)? configureProviders,
    this._hostTools = true,
  }) : _providers = providers ?? ModelProviders.current,
       _configureProviders = configureProviders ?? piProviderSetup {
    _sessionId = _context.resume?.id ?? newPiSessionId();
    _sessionPath = _context.resume?.path;
    _resumeHistory = _context.resume != null;
    _selectedModel =
        _context.settings[KernelChoiceKind.model.name] ??
        _providers.defaultModel ??
        _providers.firstModel;
    model = LocalChoice(
      const [],
      onChanged: (id) => unawaited(_selectModel(id)),
    );
    permission = LocalChoice(const [
      KernelOption(
        'ask',
        'Ask before actions',
        Icons.shield_outlined,
        'Confirm commands, edits, and other tools; allow file reads.',
      ),
      KernelOption(
        'full',
        'Full access',
        Icons.lock_open_rounded,
        'Allow Pi to run tools without confirmation.',
        caution: true,
      ),
    ], onChanged: (id) => unawaited(_selectPermission(id)));
    permission.reported =
        _context.settings[KernelChoiceKind.permission.name] == 'full'
        ? 'full'
        : 'ask';
    _thinking = _context.settings[KernelChoiceKind.effort.name] ?? 'medium';
    effort = _PiEffort(this);
    _translator = PiTranslator(emit: emit, nextSeq: () => nextSeq);
    _providers.addListener(_providersChanged);
  }

  @override
  final KernelDescriptor descriptor;
  final KernelContext _context;
  final PiTransportFactory _start;
  final ModelProviders _providers;
  final Future<PiProviderSetup> Function(ModelProviders) _configureProviders;
  final bool _hostTools;
  late final PiTranslator _translator;
  PiTransport? _transport;
  PiHostBridge? _bridge;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<void>? _starting;
  final _launches = <Future<void>>{};
  final _pending = <String, Completer<Map<String, Object?>>>{};
  final _queue = Queue<KernelTurn>();
  final _sent = <String>{};
  final _uiRequests = <String, Map<String, Object?>>{};
  final _hostAsks = <String, Completer<ApprovalDecision?>>{};
  final _modelRecords = <String, Map<String, Object?>>{};
  List<PiModelBinding> _bindings = const [];
  List<String> _thinkingLevels = const [
    'off',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
  ];
  int _request = 0;
  int _generation = 0;
  bool _disposed = false;
  bool _draining = false;
  bool _cancelled = false;
  bool _resumeHistory = false;
  bool _staleProviders = false;
  bool _loading = false;
  KernelTurn? _turn;
  Stopwatch? _worked;
  Stopwatch? _callTimer;
  DateTime? _callAt;
  Duration? _firstToken;
  Completer<void>? _toolCancelled;
  late String _sessionId;
  String? _sessionPath;
  String? _selectedModel;
  String _thinking = 'medium';
  int _contextWindow = 0;
  KernelHealth _health = KernelHealth.idle;
  List<KernelCommand> _commands = const [];
  Future<void> _stopped = Future.value();
  @override
  EditWatch? editWatch;

  @override
  KernelHealth get health => _health;
  @override
  String? get sessionId => _sessionId;
  @override
  Future<void> get stopped async {
    while (_launches.isNotEmpty) {
      await Future.wait(
        _launches.map((launch) => launch.catchError((Object _) {})).toList(),
      );
    }
    await _stopped;
  }

  @override
  late final LocalChoice model;
  @override
  late final LocalChoice permission;
  @override
  late final ModelSetting effort;
  @override
  int get contextWindow => _contextWindow;
  @override
  List<KernelCommand> get commands => [
    const KernelCommand(
      'compact',
      'Compact the Pi conversation',
      Icons.compress,
    ),
    const KernelCommand(
      'stats',
      'Show Pi session statistics',
      Icons.receipt_long_outlined,
    ),
    ..._commands,
  ];
  @override
  bool get loadingHistory => _loading;
  @override
  bool get hasEarlierHistory => false;
  @override
  bool get loadingEarlier => false;
  @override
  Future<void> loadEarlier() async {}

  void _setHealth(KernelHealth value) {
    _health = value;
    emitInfoChanged();
  }

  Future<Map<String, Object?>> _rpc(
    String type, [
    Map<String, Object?> fields = const {},
  ]) async {
    final transport = _transport;
    if (transport == null) throw StateError('Pi is not running');
    final id = 'desktop-${++_request}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    try {
      transport.write({'id': id, 'type': type, ...fields});
      return await completer.future.timeout(const Duration(seconds: 45));
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _ensure() {
    if (_disposed) return Future.error(StateError('Pi kernel is disposed'));
    if (_transport != null && _health.status == KernelHealthStatus.ready) {
      return Future.value();
    }
    if (_starting case final starting?) {
      return starting.then((_) {
        if (!_disposed &&
            _transport == null &&
            _health.status != KernelHealthStatus.failed) {
          return _ensure();
        }
      });
    }
    late final Future<void> starting;
    starting = _launch().whenComplete(() {
      _launches.remove(starting);
      if (identical(_starting, starting)) _starting = null;
    });
    _starting = starting;
    _launches.add(starting);
    return starting;
  }

  Future<void> _launch() async {
    final generation = _generation;
    PiHostBridge? bridge;
    PiTransport? launched;
    var adopted = false;
    _setHealth(const KernelHealth(KernelHealthStatus.starting));
    try {
      await _stopped;
      if (_disposed || generation != _generation) return;
      final cwd = _context.cwd;
      if (cwd == null || cwd.isEmpty) {
        throw StateError('Open a project folder to start Pi.');
      }
      final setup = await _configureProviders(_providers);
      if (_disposed || generation != _generation) return;
      _bindings = setup.bindings;
      final selected = _binding(_selectedModel);
      final native = _selectedModel != null && selected == null
          ? parseModelRef(_selectedModel)
          : null;
      if (_hostTools) {
        bridge = await startPiHostTools(
          cwd: cwd,
          sessionId: _sessionId,
          ask: _askHost,
          cancelled: () => _toolCancelled?.future,
          editWatch: () => editWatch,
        );
      }
      if (_disposed || generation != _generation) return;
      final workspace = _context.workspace?.call();
      final transport = launched = await _start(
        PiLaunch(
          cwd: cwd,
          sessionId: _sessionId,
          sessionPath: _sessionPath,
          provider: selected?.provider ?? native?.provider,
          model: selected?.model ?? native?.model,
          thinking: _thinking,
          permission: workspace?.approvesAll == true
              ? 'full'
              : permission.selected ?? 'ask',
          instructions: workspace?.instructions ?? '',
          ownPrompt: workspace?.ownPrompt ?? false,
          tools: workspace?.tools == null
              ? null
              : [for (final tool in workspace!.tools!) _piToolName(tool)],
          environment: {...setup.environment, ...?bridge?.environment},
        ),
      );
      if (_disposed || generation != _generation) return;
      adopted = true;
      _bridge = bridge;
      _transport = transport;
      _subscription = transport.messages.listen(
        _onMessage,
        onError: (Object error) => _failed(error),
      );
      final state = await _rpc('get_state');
      _applyState(state);
      final available = await _rpc('get_available_models');
      _applyModels(available['models']);
      await _loadThinkingLevels();
      final commands = await _rpc('get_commands');
      _commands = [
        for (final item
            in commands['commands'] is List
                ? commands['commands'] as List
                : const [])
          if (item is Map &&
              item['name'] is String &&
              !'${item['name']}'.startsWith('desktop-'))
            KernelCommand(
              item['name'] as String,
              item['description'] as String? ?? '',
              Icons.terminal_rounded,
            ),
      ];
      if (_resumeHistory) {
        _loading = true;
        emitInfoChanged();
        final history = await _rpc('get_messages');
        if (history['messages'] case final List messages) {
          for (final message in messages) {
            if (message is Map) {
              _translator.message(
                message.cast<String, Object?>(),
                history: true,
              );
            }
          }
        }
        _resumeHistory = false;
        _loading = false;
      }
      if (!_disposed && generation == _generation) {
        _staleProviders = false;
        _setHealth(KernelHealth.ready);
      }
    } on Object catch (error) {
      _loading = false;
      if (!_disposed && generation == _generation) {
        _failed(error);
        rethrow;
      }
    } finally {
      if (!adopted) {
        launched?.close();
        await launched?.exited;
        await bridge?.close();
      }
    }
  }

  PiModelBinding? _binding(String? ref) =>
      _bindings.where((binding) => binding.ref == ref).firstOrNull;
  String _refFor(String provider, String model) =>
      _bindings
          .where(
            (binding) => binding.provider == provider && binding.model == model,
          )
          .firstOrNull
          ?.ref ??
      modelRef(provider, model);

  void _applyState(Map<String, Object?> state) {
    _sessionId = state['sessionId'] as String? ?? _sessionId;
    _sessionPath = state['sessionFile'] as String? ?? _sessionPath;
    if (state['model'] case final Map value) {
      _applyModel(value.cast<String, Object?>());
    }
    _thinking = state['thinkingLevel'] as String? ?? _thinking;
    emitInfoChanged();
  }

  void _applyModel(Map<String, Object?> value) {
    if ((value['provider'], value['id']) case (
      final String provider,
      final String id,
    )) {
      _selectedModel = _refFor(provider, id);
      model.reported = _selectedModel;
      _modelRecords[_selectedModel!] = value;
      _contextWindow = (value['contextWindow'] as num?)?.toInt() ?? 0;
    }
    emitInfoChanged();
  }

  void _applyModels(Object? raw) {
    final options = <KernelOption>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final value = entry.cast<String, Object?>();
        if ((value['provider'], value['id']) case (
          final String provider,
          final String id,
        )) {
          final ref = _refFor(provider, id);
          _modelRecords[ref] = value;
          options.add(
            KernelOption(
              ref,
              value['name'] as String? ?? id,
              Icons.auto_awesome_rounded,
              id,
              group: KernelOptionGroup(
                provider,
                _providers.resolve(ref)?.$1.name ?? provider,
              ),
            ),
          );
        }
      }
    }
    model.options = options;
    model.reported = _selectedModel;
    emitInfoChanged();
  }

  Future<void> _loadThinkingLevels() async {
    final result = await _rpc('get_available_thinking_levels');
    final levels = result['levels'];
    if (levels is List) _thinkingLevels = levels.whereType<String>().toList();
    emitInfoChanged();
  }

  @override
  void prepare() {
    if (!_disposed) unawaited(_ensure().catchError((Object _) {}));
  }

  @override
  void send(KernelTurn turn) {
    if (_disposed || !_sent.add(turn.id)) return;
    _queue.add(turn);
    emit(
      ItemUpserted(
        nextSeq,
        turn.id,
        UserMessageItem(
          text: turn.text,
          images: turn.images,
          queued: _turn != null,
          sentAt: DateTime.now(),
        ),
      ),
    );
    if (turn.now && _turn != null) {
      _queue.remove(turn);
      _queue.addFirst(turn);
      cancel();
    }
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_disposed || _draining || _turn != null || _queue.isEmpty) return;
    _draining = true;
    final turn = _queue.removeFirst();
    _turn = turn;
    _cancelled = false;
    _worked = Stopwatch()..start();
    _toolCancelled = Completer<void>();
    _translator.beginTurn();
    emit(
      ItemUpserted(
        nextSeq,
        turn.id,
        UserMessageItem(
          text: turn.text,
          images: turn.images,
          sentAt: DateTime.now(),
        ),
      ),
    );
    emit(TurnStarted(nextSeq, turn.id));
    try {
      await _ensure();
      if (_disposed || _turn != turn) return;
      if (_cancelled) {
        _finish(interrupted: true);
        return;
      }
      if (turn.text.trim() == '/stats') {
        final stats = await _rpc('get_session_stats');
        _translator.notice(
          const JsonEncoder.withIndent('  ').convert(stats),
          kind: NoticeKind.command,
        );
        _finish();
      } else if (turn.text.trim() == '/compact' ||
          turn.text.startsWith('/compact ')) {
        await _rpc('compact', {
          'customInstructions': turn.text.substring('/compact'.length).trim(),
        });
        _finish();
      } else {
        final result = await _rpc('prompt', {
          'message': [
            turn.text,
            ...turn.notes.map(
              (note) => '<system-reminder>\n$note\n</system-reminder>',
            ),
          ].join('\n\n'),
          if (turn.images.isNotEmpty)
            'images': [
              for (final image in turn.images)
                {
                  'type': 'image',
                  'data': base64Encode(image.bytes),
                  'mimeType': image.mediaType,
                },
            ],
        });
        if (result['disposition'] == 'handled' && _turn == turn) _finish();
      }
    } on Object catch (error) {
      if (!_disposed && _turn == turn) {
        _translator.notice('$error');
        _finish(interrupted: true);
      }
    } finally {
      _draining = false;
      if (_turn == null && _queue.isNotEmpty) unawaited(_drain());
    }
  }

  void _finish({bool interrupted = false}) {
    final turn = _turn;
    if (turn == null) return;
    _turn = null;
    _worked?.stop();
    _translator.completeStreaming();
    _resolveQuestions();
    _cancelTools();
    emit(
      TurnEnded(
        nextSeq,
        turn.id,
        interrupted: interrupted || _cancelled,
        worked: _worked?.elapsed,
        usage: TurnUsage(
          inputTokens: _translator.inputTokens,
          outputTokens: _translator.outputTokens,
          costUsd: _translator.cost,
        ),
      ),
    );
    emit(ActivityReported(nextSeq, null));
    if (!_disposed) {
      if (_transport != null) unawaited(_refresh().catchError((Object _) {}));
      if (_staleProviders && _queue.isEmpty) _disconnect();
      if (!_draining) unawaited(_drain());
    }
  }

  Future<void> _refresh() async {
    final generation = _generation;
    final state = await _rpc('get_state');
    if (_disposed || generation != _generation) return;
    _applyState(state);
    final stats = await _rpc('get_session_stats');
    if (_disposed || generation != _generation) return;
    if (stats['contextUsage'] case final Map usage) {
      final window =
          (usage['contextWindow'] as num?)?.toInt() ?? _contextWindow;
      final used = (usage['tokens'] as num?)?.toInt();
      if (used != null) {
        emit(UsageReported(nextSeq, ContextUsage(window: window, used: used)));
      }
    }
    emit(
      StatsReported(
        nextSeq,
        UsageStats(costUsd: (stats['cost'] as num?)?.toDouble()),
      ),
    );
  }

  void _onMessage(Map<String, Object?> message) {
    if (_disposed) return;
    if (message['type'] == 'response') {
      final completer = _pending[message['id']];
      if (completer == null || completer.isCompleted) return;
      if (message['success'] == false) {
        completer.completeError(
          StateError(message['error'] as String? ?? 'Pi command failed'),
        );
      } else {
        final data = message['data'];
        completer.complete(data is Map ? data.cast<String, Object?>() : {});
      }
      return;
    }
    if (message['type'] == 'message_start' &&
        message['message'] is Map &&
        (message['message'] as Map)['role'] == 'assistant') {
      _callAt = DateTime.now();
      _callTimer = Stopwatch()..start();
      _firstToken = null;
    } else if (message['type'] == 'message_update') {
      _firstToken ??= _callTimer?.elapsed;
    } else if (message['type'] == 'message_end' &&
        message['message'] is Map &&
        (message['message'] as Map)['role'] == 'assistant') {
      final answer = (message['message'] as Map).cast<String, Object?>();
      final provider = answer['provider'] as String?;
      final modelId = answer['model'] as String?;
      final ref = provider == null || modelId == null
          ? _selectedModel
          : _refFor(provider, modelId);
      if (ref != null) {
        recordPiUsage(
          answer,
          providers: _providers,
          modelRef: ref,
          started: _callAt ?? DateTime.now(),
          duration: _callTimer?.elapsed ?? Duration.zero,
          firstToken: _firstToken,
          session: _sessionId,
          promptId: _turn?.id,
        );
      }
    }
    switch (message['type']) {
      case 'transport_exit':
        _failed(
          StateError(
            'Pi exited (${message['code']}). ${message['stderr'] ?? ''}'.trim(),
          ),
        );
      case 'extension_ui_request':
        _interaction(message);
      case 'agent_settled':
        _finish(interrupted: message['aborted'] == true);
      case 'auto_compaction_start':
        emit(
          ActivityReported(
            nextSeq,
            KernelActivity(KernelActivityKind.compacting, DateTime.now()),
          ),
        );
      case 'auto_compaction_end':
        emit(ActivityReported(nextSeq, null));
        _translator.notice(
          message['errorMessage'] as String? ??
              'Pi compacted the conversation.',
          kind: NoticeKind.compaction,
        );
      case 'auto_retry_start':
        _translator.notice(
          message['errorMessage'] as String? ?? 'Pi is retrying the request.',
          kind: NoticeKind.retry,
        );
      default:
        _translator.handle(message);
    }
  }

  void _interaction(Map<String, Object?> message) {
    final id = message['id'] as String?;
    if (id == null) return;
    final method = message['method'];
    if (method == 'notify') {
      _translator.notice(
        message['message'] as String? ?? '',
        kind: message['notifyType'] == 'error'
            ? NoticeKind.error
            : NoticeKind.info,
      );
      return;
    }
    if (!const {'confirm', 'select', 'input', 'editor'}.contains(method)) {
      return;
    }
    _uiRequests[id] = message;
    final title = message['title'] as String? ?? 'Pi';
    final InteractionRequest request;
    if (method == 'confirm') {
      request = ApprovalRequest(
        id: id,
        title: title,
        toolName: 'Pi',
        preview: TextPreview(message['message'] as String? ?? ''),
      );
    } else {
      request = QuestionRequest(
        id: id,
        title: title,
        questions: [
          Question(
            prompt:
                message['message'] as String? ??
                message['placeholder'] as String? ??
                title,
            allowOther: method != 'select',
            options: [
              for (final option
                  in message['options'] is List
                      ? message['options'] as List
                      : const [])
                if (option is String) QuestionOption(option),
            ],
          ),
        ],
      );
    }
    emit(InteractionRequested(nextSeq, request));
    if (message['timeout'] case final num timeout) {
      Future<void>.delayed(Duration(milliseconds: timeout.toInt()), () {
        if (_uiRequests.remove(id) != null && !_disposed) {
          _transport?.write({
            'type': 'extension_ui_response',
            'id': id,
            'cancelled': true,
          });
          emit(InteractionResolved(nextSeq, id));
        }
      });
    }
  }

  Future<ApprovalDecision?> _askHost(ApprovalRequest request) {
    if (_disposed) return Future.value(null);
    final id = 'pi-host-${++_request}';
    final completer = Completer<ApprovalDecision?>();
    _hostAsks[id] = completer;
    emit(
      InteractionRequested(
        nextSeq,
        ApprovalRequest(
          id: id,
          title: request.title,
          toolName: request.toolName,
          reason: request.reason,
          preview: request.preview,
          alwaysAllowLabel: request.alwaysAllowLabel,
        ),
      ),
    );
    return completer.future;
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    if (_hostAsks.remove(requestId) case final pending?) {
      pending.complete(
        answer is ApprovalAnswer ? answer.decision : ApprovalDecision.deny,
      );
      emit(InteractionResolved(nextSeq, requestId));
      return;
    }
    final request = _uiRequests.remove(requestId);
    if (request == null) return;
    _transport?.write({
      'type': 'extension_ui_response',
      'id': requestId,
      if (answer is ApprovalAnswer)
        'confirmed': answer.decision != ApprovalDecision.deny
      else if (answer is QuestionAnswer && !answer.skipped)
        'value': answer.picks.expand((pick) => pick).join('\n')
      else
        'cancelled': true,
    });
    emit(InteractionResolved(nextSeq, requestId));
  }

  void _resolveQuestions() {
    for (final id in _uiRequests.keys.toList()) {
      _transport?.write({
        'type': 'extension_ui_response',
        'id': id,
        'cancelled': true,
      });
      emit(InteractionResolved(nextSeq, id));
    }
    _uiRequests.clear();
    for (final MapEntry(key: id, value: pending) in _hostAsks.entries) {
      if (!pending.isCompleted) pending.complete(null);
      emit(InteractionResolved(nextSeq, id));
    }
    _hostAsks.clear();
  }

  void _cancelTools() {
    final cancel = _toolCancelled;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  @override
  void cancel() {
    if (_turn == null) return;
    _cancelled = true;
    _cancelTools();
    _resolveQuestions();
    if (_transport != null) {
      unawaited(_rpc('abort').catchError((Object _) => <String, Object?>{}));
    }
  }

  @override
  Future<bool> cancelQueued(String turnId) async {
    final queued = _queue.where((turn) => turn.id == turnId).firstOrNull;
    if (queued == null) return false;
    _queue.remove(queued);
    emit(ItemRemoved(nextSeq, turnId));
    return true;
  }

  @override
  void sendQueuedNow(String turnId) {
    final queued = _queue.where((turn) => turn.id == turnId).firstOrNull;
    if (queued == null) return;
    _queue.remove(queued);
    _queue.addFirst(queued);
    cancel();
    if (_turn == null) unawaited(_drain());
  }

  @override
  void moveQueued(String turnId, int index) {
    final turns = _queue.toList();
    final at = turns.indexWhere((turn) => turn.id == turnId);
    if (at < 0) return;
    final turn = turns.removeAt(at);
    turns.insert(index.clamp(0, turns.length), turn);
    _queue
      ..clear()
      ..addAll(turns);
    emit(QueueReordered(nextSeq, turns.map((turn) => turn.id).toList()));
  }

  Future<void> _selectModel(String id) async {
    final previous = _selectedModel;
    model.reported = previous;
    try {
      await _ensure();
      final custom = _binding(id);
      final parsed = parseModelRef(id);
      if (custom == null && parsed == null) {
        throw StateError('Unknown Pi model: $id');
      }
      final result = await _rpc('set_model', {
        'provider': custom?.provider ?? parsed!.provider,
        'modelId': custom?.model ?? parsed!.model,
      });
      _applyModel(result);
      await _loadThinkingLevels();
    } on Object catch (error) {
      model.reported = previous;
      _translator.notice('$error');
    }
    emitInfoChanged();
  }

  Future<void> _selectPermission(String id) async {
    if (_transport != null) {
      try {
        await _rpc('prompt', {'message': '/desktop-permission $id'});
      } on Object catch (error) {
        _translator.notice('$error');
      }
    }
    emitInfoChanged();
  }

  Future<void> _selectThinking(String modelId, String id) async {
    try {
      if (modelId != _selectedModel) await _selectModel(modelId);
      await _ensure();
      await _rpc('set_thinking_level', {'level': id});
      _thinking = id;
      _applyState(await _rpc('get_state'));
    } on Object catch (error) {
      _translator.notice('$error');
    }
    emitInfoChanged();
  }

  @override
  void rename(String title) {
    unawaited(() async {
      try {
        await _ensure();
        await _rpc('set_session_name', {'name': title});
        emit(SessionRenamed(nextSeq, title));
      } on Object catch (error) {
        _translator.notice('$error');
      }
    }());
  }

  void _providersChanged() {
    _staleProviders = true;
    if (_turn == null) _disconnect();
  }

  void _failed(Object error) {
    if (_disposed) return;
    _setHealth(KernelHealth(KernelHealthStatus.failed, message: '$error'));
    _disconnect();
    if (_turn != null) {
      _translator.notice('$error');
      _finish(interrupted: true);
    }
  }

  void _disconnect() {
    _generation++;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(StateError('Pi stopped'));
    }
    _pending.clear();
    final transport = _transport;
    _transport = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    transport?.close();
    final bridge = _bridge;
    _bridge = null;
    _stopped = Future.wait<void>([
      _stopped,
      if (transport != null) transport.exited,
      if (bridge != null) bridge.close(),
    ]).then((_) {});
  }

  @override
  void restart() {
    if (_disposed) return;
    _disconnect();
    _starting = null;
    _setHealth(KernelHealth.idle);
    prepare();
  }

  @override
  void release() {
    if (_turn == null && !_disposed) {
      _disconnect();
      _setHealth(KernelHealth.idle);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _resolveQuestions();
    _cancelTools();
    _disposed = true;
    _providers.removeListener(_providersChanged);
    _disconnect();
    closeEvents();
  }

  static String _piToolName(String tool) => switch (tool) {
    'Read' => 'read',
    'Write' => 'write',
    'Edit' => 'edit',
    'Bash' => 'bash',
    'Grep' => 'grep',
    'Glob' => 'find',
    _ => tool,
  };
}

class _PiEffort implements ModelSetting {
  _PiEffort(this.kernel);
  final PiKernel kernel;
  @override
  List<KernelOption> optionsFor(String model) => [
    for (final level
        in (model == kernel._selectedModel
            ? kernel._thinkingLevels
            : const ['off', 'low', 'medium', 'high', 'xhigh', 'max']))
      KernelOption(
        level,
        level,
        Icons.psychology_outlined,
        'Pi thinking: $level',
      ),
  ];
  @override
  String? get selected => kernel._thinking;
  @override
  String? selectedFor(String model) => kernel._thinking;
  @override
  bool get toggle => false;
  @override
  void select(String model, String id) =>
      unawaited(kernel._selectThinking(model, id));
}

String newPiSessionId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
