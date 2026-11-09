import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_desktop/update/update_manifest.dart';
import 'package:pi_desktop/update/version.dart';

final _signature = base64.encode(List.filled(64, 7));

Map<String, Object?> _asset({
  String url = 'https://updates.example/releases/1.2.0/pi-desktop-1.2.0-setup.exe',
  Object? size = 1000,
  Object? sha256,
  Object? signature,
}) => {
  'url': url,
  'size': ?size,
  'sha256': sha256 ?? 'a' * 64,
  'signature': signature ?? _signature,
};

String _manifest({
  Object? version = '1.2.0+12',
  Map<String, Object?>? platforms,
  Object? notes,
  Object? minimumVersion,
}) => jsonEncode({
  'version': ?version,
  'pubDate': '2026-10-04T00:00:00Z',
  'notes': ?notes,
  'minimumVersion': ?minimumVersion,
  'platforms':
      platforms ??
      {
        'windows-x64': _asset(),
        'macos-arm64': _asset(
          url: 'https://updates.example/releases/1.2.0/pi-desktop-1.2.0-mac.zip',
        ),
      },
});

Matcher _invalid(String part) => throwsA(
  isA<UpdateManifestException>().having(
    (e) => e.message,
    'message',
    contains(part),
  ),
);

UpdateManifest _parse(
  String text, {
  UpdateUrlPolicy policy = const UpdateUrlPolicy(
    extraOrigins: {'https://updates.example'},
  ),
}) => UpdateManifest.parse(text, policy: policy);

void main() {
  group('UpdateManifest', () {
    test('reads the release, its notes and downloads', () {
      final manifest = _parse(
        _manifest(notes: {'en': 'Fixes', 'zh': '修复'}, minimumVersion: '1.0.0'),
      );
      expect(manifest.version, AppVersion.parse('1.2.0+12'));
      expect(manifest.pubDate, DateTime.utc(2026, 10, 4));
      expect(manifest.minimumVersion, AppVersion.parse('1.0.0'));
      expect(manifest.notesFor('zh'), '修复');
      expect(manifest.notesFor('fr'), 'Fixes');
      final asset = manifest.assetFor('windows-x64')!;
      expect(asset.size, 1000);
      expect(asset.sha256, 'a' * 64);
      expect(asset.fileName, 'pi-desktop-1.2.0-setup.exe');
      expect(manifest.platforms, containsAll(['windows-x64', 'macos-arm64']));
    });

    test('names a download by its path, whatever its query', () {
      // tool/release_manifest.dart ends links in the file's hash, so a
      // release redone is not served from the CDN's cache of the old one;
      // and adds `downloads`, for the site, which the app has no use for.
      final text = jsonEncode({
        ...jsonDecode(
          _manifest(
            platforms: {
              'windows-x64': _asset(
                url:
                    'https://updates.example/releases/1.2.0/'
                    'pi-desktop-1.2.0-setup.exe?sha256=0123456789abcdef',
              ),
            },
          ),
        ),
        'downloads': {
          'macos': {'url': 'https://updates.example/x.dmg', 'size': 1},
        },
      });
      final asset = _parse(text).assetFor('windows-x64')!;
      expect(asset.fileName, 'pi-desktop-1.2.0-setup.exe');
      expect(asset.url.query, 'sha256=0123456789abcdef');
    });

    test('a platform it has no download for has none', () {
      final manifest = _parse(_manifest(platforms: {'windows-x64': _asset()}));
      expect(manifest.assetFor('macos-arm64'), isNull);
    });

    test('notes may be one text, or none', () {
      expect(_parse(_manifest(notes: 'Fixes')).notesFor('zh'), 'Fixes');
      expect(_parse(_manifest()).notesFor('en'), isNull);
    });

    test('is refused without what it needs', () {
      expect(() => _parse('not json'), _invalid('not JSON'));
      expect(() => _parse('[]'), _invalid('not an object'));
      expect(() => _parse(_manifest(version: null)), _invalid('version'));
      expect(() => _parse(_manifest(version: 'latest')), _invalid('version'));
      expect(
        () => _parse(_manifest(minimumVersion: 'soon')),
        _invalid('minimumVersion'),
      );
      expect(
        () => _parse(jsonEncode({'version': '1.0.0'})),
        _invalid('platforms'),
      );
    });

    test("a platform's wrong entry keeps only that platform's users", () {
      final manifest = _parse(
        _manifest(
          platforms: {
            'windows-x64': _asset(size: null),
            'macos-arm64': _asset(
              url: 'https://updates.example/releases/1.2.0/pi-desktop-1.2.0-mac.zip',
            ),
          },
        ),
      );
      expect(manifest.assetFor('macos-arm64'), isNotNull);
      expect(() => manifest.assetFor('windows-x64'), _invalid('size'));
    });

    test('a field missing or wrong in a download is refused', () {
      UpdateManifest entry(Map<String, Object?> asset) =>
          _parse(_manifest(platforms: {'windows-x64': asset}));
      for (final (asset, field) in [
        (_asset(size: 0), 'size'),
        (_asset(size: '1000'), 'size'),
        (_asset(sha256: 'abc'), 'sha256'),
        (_asset(sha256: 'g' * 64), 'sha256'),
        (_asset(signature: 'not base64!'), 'signature'),
        (_asset(signature: base64.encode([1, 2, 3])), 'signature'),
        ({..._asset()}..remove('url'), 'url'),
      ]) {
        expect(
          () => entry(asset).assetFor('windows-x64'),
          _invalid(field),
          reason: '$asset',
        );
      }
    });

    test('only configured origins are allowed', () {
      final policy = UpdateUrlPolicy.forManifest(
        Uri.parse('https://updates.example/feed'),
      );
      expect(policy.allows(Uri.parse('https://updates.example/file')), isTrue);
      for (final url in [
        'https://github.com/zkldwxz/pi-desktop',
        'https://cdn.updates.example/file',
        'https://user@updates.example/file',
        'http://updates.example/file',
      ]) {
        expect(policy.allows(Uri.parse(url)), isFalse, reason: url);
      }
      expect(
        const UpdateUrlPolicy().allows(
          Uri.parse('https://updates.example/file'),
        ),
        isFalse,
      );
    });

    test('writes itself back as it reads', () {
      final manifest = _parse(
        _manifest(notes: {'en': 'Fixes'}, minimumVersion: '1.0.0'),
      );
      final again = _parse(jsonEncode(manifest.toJson()));
      expect(again.version, manifest.version);
      expect(again.minimumVersion, manifest.minimumVersion);
      expect(again.notes, manifest.notes);
      expect(again.pubDate, manifest.pubDate);
      expect(
        again.assetFor('macos-arm64')!.toJson(),
        manifest.assetFor('macos-arm64')!.toJson(),
      );
    });
  });
}
