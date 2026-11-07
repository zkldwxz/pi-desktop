import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../claude_code/claude_sdk_tools.dart';
import '../agent_kernel.dart' show EditWatch;
import 'pi_host_tools.dart';
import '../../remote/remote_location.dart';

Future<PiHostBridge?> startPiHostTools({
  required String cwd,
  required String sessionId,
  required ClaudeSdkAsk ask,
  required Future<void>? Function() cancelled,
  required EditWatch? Function() editWatch,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final random = Random.secure();
  final token = base64UrlEncode(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
  final bridge = _Bridge(server, token);
  server.listen((request) async {
    final response = request.response;
    try {
      if (request.method != 'POST' ||
          request.headers.value(HttpHeaders.authorizationHeader) !=
              'Bearer $token') {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      final bytes = <int>[];
      await for (final chunk in request) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          response.statusCode = HttpStatus.requestEntityTooLarge;
          return;
        }
        bytes.addAll(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        response.statusCode = HttpStatus.badRequest;
        return;
      }
      if (decoded['method'] == 'desktop/before_edit' ||
          decoded['method'] == 'desktop/after_edit') {
        final params = decoded['params'];
        final path = params is Map ? params['path'] : null;
        if (path is! String) {
          response.statusCode = HttpStatus.badRequest;
          return;
        }
        final host = RemoteLocation.hostOf(cwd);
        final paths = host == null ? p.context : RemoteLocation.pathsOf(cwd);
        final resolved = paths.isAbsolute(path)
            ? path
            : paths.normalize(paths.join(RemoteLocation.pathOf(cwd), path));
        final absolute = RemoteLocation.of(host, resolved);
        final watch = editWatch();
        if (decoded['method'] == 'desktop/before_edit') {
          await watch?.beforeEdit(absolute);
        } else {
          await watch?.afterEdit(absolute);
        }
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': decoded['id'],
            'result': <String, Object?>{},
          }),
        );
        return;
      }
      final result = await ClaudeSdkTools.handle(
        decoded,
        ClaudeSdkCall(
          cwd: cwd,
          sessionId: sessionId,
          ask: ask,
          cancelled: cancelled(),
        ),
      );
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(result));
    } on Object {
      response.statusCode = HttpStatus.internalServerError;
      response.write('Desktop tool request failed');
    } finally {
      await response.close();
    }
  });
  return bridge;
}

class _Bridge implements PiHostBridge {
  _Bridge(this.server, this.token);
  final HttpServer server;
  final String token;

  @override
  Map<String, String> get environment => {
    'PI_DESKTOP_HOST_URL': 'http://127.0.0.1:${server.port}/',
    'PI_DESKTOP_HOST_TOKEN': token,
  };
  @override
  Future<void> close() => server.close(force: true).then((_) {});
}
