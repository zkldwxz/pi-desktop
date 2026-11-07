import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_desktop/channel/account/account_api.dart';
import 'package:pi_desktop/channel/account/account_send_io.dart';
import 'package:pi_desktop/channel/account/newapi_adapter.dart';
import 'package:pi_desktop/channel/account/sub2api_adapter.dart';
import 'package:pi_desktop/channel/channel_setup.dart';

import 'account_fakes.dart';

void main() {
  late HttpServer server;
  late Uri base;

  // Real requests, to a server of the test's own.
  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) {
      final response = request.response..statusCode = HttpStatus.forbidden;
      if (request.uri.path == '/firewall') {
        // As Cloudflare's "Sorry, you have been blocked".
        response.headers.contentType = ContentType.html;
        response.write('<title>Attention Required! | Cloudflare</title>');
      } else {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'code': 403, 'message': 'token revoked'}));
      }
      response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('a firewall\'s page in place of the site is not a sign-out', () async {
    await expectLater(
      sendToAccountSite('POST', base.replace(path: '/firewall')),
      throwsA(isA<AccountBlocked>().having((e) => e.host, 'host', '127.0.0.1')),
    );
  });

  test('the site\'s own 403 comes back, for the adapter to read', () async {
    final response = await sendToAccountSite(
      'POST',
      base.replace(path: '/api/v1/auth/refresh'),
    );
    expect(response.status, 403);
    expect(response.json, {'code': 403, 'message': 'token revoked'});
  });
  for (final type in ChannelAccountType.values) {
    test(
      '${type.id} adapter exchanges real HTTP requests and parses responses',
      () async {
        final fixture = type == ChannelAccountType.newApi
            ? newApiSite()
            : sub2apiSite();
        final local = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => local.close(force: true));
        local.listen((request) async {
          final body = await utf8.decoder.bind(request).join();
          final headers = <String, String>{};
          request.headers.forEach((name, values) {
            headers[name] = values.join(', ');
          });
          final result = await fixture.send(
            request.method,
            request.uri,
            headers: {
              'Cookie': headers['cookie'] ?? '',
              'Authorization': headers['authorization'] ?? '',
              'Origin': headers['origin'] ?? '',
            },
            json: body.isEmpty ? null : jsonDecode(body),
          );
          request.response.statusCode = result.status;
          request.response.headers.contentType = ContentType.json;
          for (final cookie in result.cookies.entries) {
            request.response.cookies.add(Cookie(cookie.key, cookie.value));
          }
          request.response.write(jsonEncode(result.json));
          await request.response.close();
        });
        final site = ChannelAccountSite(
          type: type,
          url: Uri.parse('http://127.0.0.1:${local.port}'),
        );
        final AccountAdapter adapter = type == ChannelAccountType.newApi
            ? NewApiAdapter(
                site: site,
                send: sendToAccountSite,
                credential: 'r0',
              )
            : Sub2ApiAdapter(
                site: site,
                send: sendToAccountSite,
                credential: 'rt0',
              );
        final profile = await adapter.profile();
        final keys = await adapter.keys();
        expect(
          profile.email,
          type == ChannelAccountType.newApi
              ? 'leo@example.com'
              : 'sub@example.com',
        );
        expect(profile.balance, type == ChannelAccountType.newApi ? 2.5 : 12.5);
        expect(
          adapter.credential,
          type == ChannelAccountType.newApi ? 'r1' : 'rt1',
        );
        expect(
          await adapter.reveal(keys.single),
          type == ChannelAccountType.newApi
              ? 'sk-abcdWHOLEwxyz'
              : 'sk-0123456789abcdef0123',
        );
        final refresh = fixture.sent.first;
        expect(refresh.method, 'POST');
        if (type == ChannelAccountType.newApi) {
          expect(refresh.headers['Cookie'], 'new_api_refresh=r0');
        } else {
          expect(refresh.json, {'refresh_token': 'rt0'});
        }
      },
    );
  }
}
