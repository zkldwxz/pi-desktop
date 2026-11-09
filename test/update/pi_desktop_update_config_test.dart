import 'dart:convert';

import 'package:pi_desktop/update/pi_desktop_update_config.dart';
import 'package:pi_desktop/update/update_signature.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final seed = base64.encode(List<int>.generate(32, (i) => i));
  final key = UpdateSignature.publicKeyOf(seed);
  Map<String, String> config(
    String url, {
    String? publicKey,
    String? localhost,
    String? origins,
  }) => {
    PiDesktopUpdateConfig.urlVariable: url,
    PiDesktopUpdateConfig.keyVariable: publicKey ?? key,
    PiDesktopUpdateConfig.localhostVariable: ?localhost,
    PiDesktopUpdateConfig.originsVariable: ?origins,
  };

  test('requires a valid independent key and URL', () {
    expect(
      PiDesktopUpdateConfig.fromEnvironment({
        PiDesktopUpdateConfig.urlVariable: '',
        PiDesktopUpdateConfig.keyVariable: '',
      }),
      isNull,
    );
    expect(
      PiDesktopUpdateConfig.fromEnvironment(
        config('https://updates.example/feed', publicKey: 'invalid'),
      ),
      isNull,
    );
    expect(
      PiDesktopUpdateConfig.fromEnvironment(
        config('http://updates.example/feed', localhost: 'true'),
      ),
      isNull,
    );
    expect(
      PiDesktopUpdateConfig.fromEnvironment(
        config('https://user@updates.example/feed'),
      ),
      isNull,
    );
  });

  test('permits HTTP only on explicitly enabled loopback', () {
    expect(
      PiDesktopUpdateConfig.fromEnvironment(
        config('http://localhost:8080/feed'),
      ),
      isNull,
    );
    final value = PiDesktopUpdateConfig.fromEnvironment(
      config('http://localhost:8080/feed', localhost: 'true'),
    )!;
    expect(
      value.policy.allows(Uri.parse('http://localhost:8080/file')),
      isTrue,
    );
    expect(
      value.policy.allows(Uri.parse('http://localhost:8081/file')),
      isFalse,
    );
    expect(
      value.policy.allows(Uri.parse('http://127.0.0.1:8080/file')),
      isFalse,
    );
  });

  test('allows only the configured exact origin', () {
    final value = PiDesktopUpdateConfig.fromEnvironment(
      config('https://updates.example/feed'),
    )!;
    expect(
      value.policy.allows(Uri.parse('https://updates.example/file')),
      isTrue,
    );
    for (final url in [
      'https://cdn.updates.example/file',
      'https://updates.example:444/file',
      'https://github.com/zkldwxz/pi-desktop',
      'https://user@updates.example/file',
      'http://updates.example/file',
    ]) {
      expect(value.policy.allows(Uri.parse(url)), isFalse, reason: url);
    }
  });

  test('additional origins are exact and obey the transport policy', () {
    final value = PiDesktopUpdateConfig.fromEnvironment(
      config(
        'https://updates.example/feed',
        localhost: 'true',
        origins: ' https://cdn.example:8443, http://localhost:8080 ',
      ),
    )!;
    for (final url in [
      'https://updates.example/file',
      'https://cdn.example:8443/file',
      'http://localhost:8080/file',
    ]) {
      expect(value.policy.allows(Uri.parse(url)), isTrue, reason: url);
    }
    for (final url in [
      'https://cdn.example/file',
      'https://sub.cdn.example:8443/file',
      'http://127.0.0.1:8080/file',
      'http://cdn.example:8443/file',
    ]) {
      expect(value.policy.allows(Uri.parse(url)), isFalse, reason: url);
    }
    for (final origin in [
      'http://cdn.example',
      'http://localhost:8080',
      'https://user@cdn.example',
      'https://cdn.example/path',
      'https://cdn.example?query',
      'https://cdn.example#fragment',
      '*.example',
    ]) {
      expect(
        PiDesktopUpdateConfig.fromEnvironment(
          config('https://updates.example/feed', origins: origin),
        ),
        isNull,
        reason: origin,
      );
    }
  });

  test('an older app\'s signatures cannot authorize pi-desktop releases', () {
    final bao = UpdateSignature.payload(
      version: '1.2.3',
      platform: 'linux-x64',
      size: 1,
      sha256: 'ab' * 32,
      context: 'baocode-update-v1',
    );
    final pi = UpdateSignature.payload(
      version: '1.2.3',
      platform: 'linux-x64',
      size: 1,
      sha256: 'ab' * 32,
      context: 'pi-desktop-update-v1',
    );
    final signature = UpdateSignature.sign(payload: bao, seed: seed);
    expect(
      UpdateSignature.verify(payload: pi, signature: signature, publicKey: key),
      isFalse,
    );
    expect(
      UpdateSignature.verify(
        payload: pi,
        signature: UpdateSignature.sign(payload: pi, seed: seed),
        publicKey: key,
      ),
      isTrue,
    );
  });
}
