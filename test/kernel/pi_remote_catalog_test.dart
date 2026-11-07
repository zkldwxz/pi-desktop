import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_desktop/kernel/pi/pi_remote_catalog.dart';

void main() {
  test(
    'remote catalog qualifies project paths and deletes on the listed host',
    () async {
      final calls = <(String, Map<String, Object?>)>[];
      final catalog = PiRemoteCatalog(
        run: (host, request) async {
          calls.add((host, request));
          return request['op'] == 'delete'
              ? 'null'
              : jsonEncode([
                  {
                    'id': 'remote-session',
                    'title': 'Remote conversation',
                    'cwd': '/work/app',
                    'path': '/home/test/.pi-desktop/pi-agent/sessions/abc/session.jsonl',
                    'updatedAt': 1760000000000,
                  },
                ]);
        },
      );
      final records = await catalog.sessionsIn('ssh://test-host/work/app');
      expect(records.single.cwd, 'ssh://test-host/work/app');
      expect(records.single.id, 'remote-session');
      expect(calls.single.$2, {'op': 'list', 'cwd': '/work/app'});
      await catalog.delete(records.single.id);
      expect(calls.last.$1, 'test-host');
      expect(calls.last.$2, {'op': 'delete', 'id': 'remote-session'});
    },
  );
  test('ambiguous session IDs cannot delete on the wrong host', () async {
    final catalog = PiRemoteCatalog(
      run: (host, request) async => jsonEncode([
        {
          'id': 'same-id',
          'title': 'Session',
          'cwd': '/project',
          'path': '/sessions/session.jsonl',
          'updatedAt': 0,
        },
      ]),
    );
    await catalog.sessionsIn('ssh://first/project');
    await catalog.sessionsIn('ssh://second/project');
    await expectLater(catalog.delete('same-id'), throwsStateError);
  });
}
