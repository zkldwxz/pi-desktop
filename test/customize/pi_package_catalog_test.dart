import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:pi_desktop/customize/pi_package_catalog.dart';

void main() {
  test('searches the registry for the gallery\'s keyword, most used first', () {
    final all = piPackageSearchUri('');
    expect(all.host, 'registry.npmjs.org');
    expect(all.path, '/-/v1/search');
    expect(all.queryParameters['text'], 'keywords:pi-package');
    expect(all.queryParameters['size'], '30');
    final some = piPackageSearchUri(' git tools ', limit: 10);
    expect(some.queryParameters['text'], 'keywords:pi-package git tools');
    expect(some.queryParameters['size'], '10');
  });

  test('reads the packages from the registry\'s answer, leaving out what '
      'is not one', () {
    final body = jsonEncode({
      'objects': [
        {
          'downloads': {'weekly': 1200},
          'package': {
            'name': '@example/pi-tools',
            'version': '1.2.0',
            'description': 'Handy tools',
            'date': '2026-11-01T10:00:00.000Z',
            'publisher': {'username': 'someone'},
            'links': {
              'npm': 'https://www.npmjs.com/package/@example/pi-tools',
              'homepage': 'https://example.com/tools',
            },
          },
        },
        {
          'package': {'name': 'pi-bare', 'version': '0.1.0'},
        },
        {
          'package': {'name': 'no-version'},
        },
        {'nothing': true},
      ],
    });
    final found = parsePiPackageSearch(body);
    expect(found.map((p) => p.name), ['@example/pi-tools', 'pi-bare']);
    final tools = found.first;
    expect(tools.source, 'npm:@example/pi-tools');
    expect(tools.description, 'Handy tools');
    expect(tools.author, 'someone');
    expect(tools.homepage, 'https://example.com/tools');
    expect(tools.weeklyDownloads, 1200);
    expect(tools.updated, DateTime.utc(2026, 11, 1, 10));
    expect(found.last.description, '');
    expect(found.last.author, isNull);
    expect(parsePiPackageSearch('{}'), isEmpty);
  });
}
