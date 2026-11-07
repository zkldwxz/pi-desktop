import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../platform/data_dir.dart';
import '../workspace/editor_launcher.dart' show openExternal;
import 'browser_bridge.dart';

/// Where BaoCode's extension is got. The store's page is the site's to say
/// (`store` in dl.baocode.dev's releases/extension/latest.json, which
/// .github/workflows/extension.yml writes): fetched once a run, kept in
/// the cache for when the site does not answer, and before the first
/// answer the page the extension's id makes.
abstract final class ExtensionStore {
  static final manifest = Uri.tryParse(
    const String.fromEnvironment('PI_DESKTOP_EXTENSION_MANIFEST_URL'),
  );

  /// Until our own store listing is configured, open the bundled extension.
  static Uri get fallback {
    const configured = String.fromEnvironment('PI_DESKTOP_EXTENSION_STORE_URL');
    return _valid(configured) ?? zip;
  }

  static Uri get zip {
    final executable = p.dirname(Platform.resolvedExecutable);
    final candidates = [
      if (Platform.isMacOS)
        p.join(
          executable,
          '..',
          'Resources',
          'pi-runtime',
          'browser-extension',
        ),
      p.join(executable, 'data', 'pi-runtime', 'browser-extension'),
      p.join(Directory.current.path, 'browser_extension'),
    ];
    return Uri.directory(
      candidates.firstWhere(
        (path) => File(p.join(path, 'manifest.json')).existsSync(),
        orElse: () => candidates.first,
      ),
    );
  }

  /// The store's page as last known: fetched, or kept; [fallback] before.
  static Uri get page => _page ?? fallback;
  static Uri? _page;

  static Future<Uri>? _fetched;

  /// Fetches the store's page, once a run (again after [reset]); [page]
  /// is it once done. Never fails: what was kept, or [fallback].
  static Future<Uri> fetch({
    @visibleForTesting Uri? from,
    @visibleForTesting String? cacheDir,
  }) {
    final source = from ?? manifest;
    if (source == null || !source.hasAuthority) return Future.value(page);
    return _fetched ??= _fetch(source, cacheDir);
  }

  /// [fetch]'s page, waiting for it [patience] at most: a click opens the
  /// page then, the one known so far if the site is slow.
  static Future<Uri> resolve({
    Duration patience = const Duration(seconds: 2),
  }) => fetch().timeout(patience, onTimeout: () => page);

  /// Opens the store's page in the user's browser.
  static Future<void> openPage() async => openExternal('${await resolve()}');

  /// Opens [zip]: the browser downloads it.
  static Future<void> openZip() => openExternal('$zip');

  @visibleForTesting
  static void reset() {
    _page = null;
    _fetched = null;
  }

  static Future<Uri> _fetch(Uri from, String? cacheDir) async {
    final kept = File(
      p.join(cacheDir ?? DataDirectory.current.cacheDir, 'browser', 'store'),
    );
    try {
      if (_valid(await kept.readAsString()) case final url?) _page = url;
    } on FileSystemException {
      // None kept yet.
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(from).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return page;
      }
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      final store = switch (jsonDecode(text)) {
        {'store': final String store} => _valid(store),
        _ => null,
      };
      if (store != null && store != _page) {
        _page = store;
        await kept.parent.create(recursive: true);
        await writeFileAtomically(kept, '$store');
      }
    } on Object catch (error) {
      debugPrint('extension store: $error');
    } finally {
      client.close(force: true);
    }
    return page;
  }

  static const _timeout = Duration(seconds: 8);

  /// [text] as the store's page: https, on the store's own hosts.
  static Uri? _valid(String text) => switch (Uri.tryParse(text.trim())) {
    final url?
        when url.scheme == 'https' &&
            (url.host == 'chromewebstore.google.com' ||
                url.host == 'chrome.google.com') &&
            url.userInfo.isEmpty &&
            url.pathSegments.contains(BrowserBridge.extensionIds.first) =>
      url,
    _ => null,
  };
}
