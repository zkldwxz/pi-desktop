import 'dart:convert';
import 'dart:io';

/// The registry's answer to [uri].
Future<String> fetchNpmSearch(Uri uri) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = 'pi-desktop';
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException(
        'npm registry answered ${response.statusCode}',
        uri: uri,
      );
    }
    return await utf8.decoder.bind(response).join();
  } finally {
    client.close(force: true);
  }
}
