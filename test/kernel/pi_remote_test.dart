import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_desktop/kernel/pi/pi_remote.dart';
import 'package:pi_desktop/kernel/pi/pi_transport.dart';

import '../remote/remote_harness.dart';

void main() {
  test('streams RPC over the remote process protocol with host cwd', () async {
    final harness = await RemoteHarness.start();
    final dir = await Directory.systemTemp.createTemp('pi-remote-test-');
    addTearDown(() async {
      await harness.close();
      await dir.delete(recursive: true);
    });
    final script = File('${dir.path}/fake.sh');
    await script.writeAsString(
      '#!/bin/sh\nread line\nprintf \'{"type":"response","cwd":"%s"}\\n\' "\$PWD"\n',
    );
    await Process.run('chmod', ['+x', script.path]);
    final transport = await startRemotePiWithClient(
      PiLaunch(cwd: 'ssh://test${dir.path}', sessionId: 'test', persist: false),
      harness.client,
      agentDirectory: '${dir.path}/agent',
      options: RemotePiOptions(executable: script.path),
    );
    final messages = transport.messages.toList();
    transport.write({'type': 'get_state'});
    await transport.exited.timeout(const Duration(seconds: 10));
    final result = await messages;
    expect(result.first['cwd'], await dir.resolveSymbolicLinks());
    expect(result.last['type'], 'transport_exit');
    expect(result.last['code'], 0);
  });

  test('refuses desktop loopback without explicit forwarding', () async {
    final harness = await RemoteHarness.start();
    addTearDown(harness.close);
    await expectLater(
      startRemotePiWithClient(
        const PiLaunch(
          cwd: 'ssh://test/tmp',
          sessionId: 'test',
          environment: {'PI_DESKTOP_HOST_URL': 'http://127.0.0.1:1234/'},
        ),
        harness.client,
        agentDirectory: '/tmp/pi-agent',
      ),
      throwsStateError,
    );
  });
}
