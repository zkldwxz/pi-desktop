import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pi_desktop/kernel/pi/pi_remote_ssh.dart';
import 'package:pi_desktop/kernel/pi/pi_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('direct SSH runs a stub model turn with real PI', () async {
    final temp = await Process.run('ssh', [
      '-o',
      'BatchMode=yes',
      '-o',
      'StrictHostKeyChecking=yes',
      'linux-server',
      'mktemp -d',
    ]);
    expect(temp.exitCode, 0);
    final directory = (temp.stdout as String).trim();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      await request.drain<void>();
      requests++;
      request.response.headers.set('content-type', 'text/event-stream');
      for (final item in [
        {
          'id': 'chat-1',
          'object': 'chat.completion.chunk',
          'created': 1,
          'model': 'stub',
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'Hello from stub'},
              'finish_reason': null,
            },
          ],
        },
        {
          'id': 'chat-1',
          'object': 'chat.completion.chunk',
          'created': 1,
          'model': 'stub',
          'choices': [
            {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
          ],
          'usage': {
            'prompt_tokens': 1,
            'completion_tokens': 1,
            'total_tokens': 2,
          },
        },
      ]) {
        request.response.write('data: ${jsonEncode(item)}\n\n');
      }
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    addTearDown(() async {
      await stopRemotePiProcesses();
      await server.close(force: true);
      await Process.run('ssh', [
        '-o',
        'BatchMode=yes',
        '-o',
        'StrictHostKeyChecking=yes',
        'linux-server',
        'rm -rf -- $directory',
      ]);
    });
    final provider = {
      'id': 'desktop-test',
      'name': 'stub',
      'api': 'openai-completions',
      'baseUrl': 'http://127.0.0.1:${server.port}/v1',
      'authHeader': true,
      'headers': {},
      'keyVariable': 'PI_DESKTOP_KEY_0',
      'models': [
        {
          'type': 'chat',
          'id': 'stub',
          'name': 'stub',
          'reasoning': false,
          'input': ['text'],
          'contextWindow': 8192,
          'maxTokens': 1024,
          'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
        },
      ],
    };
    final transport = await startSshPi(
      PiLaunch(
        cwd: 'ssh://linux-server$directory',
        sessionId: 'probe',
        persist: false,
        provider: 'desktop-test',
        model: 'stub',
        environment: {
          'PI_DESKTOP_PROVIDERS': jsonEncode([provider]),
          'PI_DESKTOP_KEY_0': 'test-key',
        },
      ),
      agentDirectory: directory,
      forwardLoopback: true,
    );
    final events = <Map<String, Object?>>[];
    final settled = Completer<void>();
    final listener = transport.messages.listen((m) {
      events.add(m);
      if (m['type'] == 'agent_settled' && !settled.isCompleted) {
        settled.complete();
      }
    });
    transport.write({
      'type': 'get_available_thinking_levels',
      'id': 'thinking',
    });
    transport.write({'type': 'prompt', 'id': 'prompt', 'message': 'Say hello'});
    await settled.future.timeout(const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(requests, 1);
    expect(
      events.any((e) => e['id'] == 'prompt' && e['success'] == true),
      true,
    );
    transport.close();
    await transport.exited.timeout(const Duration(seconds: 10));
    await listener.cancel();
  }, skip: Platform.environment['PI_TEST_SSH'] != '1');
}
