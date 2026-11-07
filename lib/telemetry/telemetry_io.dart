import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import '../update/version.dart';
import 'telemetry_service.dart';

/// The explicitly configured endpoint for usage reports.
const telemetryUrlVariable = 'PI_DESKTOP_TELEMETRY_URL';
const _telemetryUrlDefine = String.fromEnvironment(telemetryUrlVariable);

/// What the app reports with where it runs; null where it reports nothing:
/// when [telemetryUrlVariable] has no valid URL.
PlatformTelemetry? platformTelemetry({
  Map<String, String>? environment,
  String? buildUrl,
}) {
  final value =
      (environment ?? Platform.environment)[telemetryUrlVariable] ??
      buildUrl ??
      _telemetryUrlDefine;
  final url = Uri.tryParse(value.trim());
  if (url == null ||
      !(url.isScheme('https') || url.isScheme('http')) ||
      url.host.isEmpty) {
    return null;
  }
  final os = Platform.operatingSystem;
  final arch = abiArch(Abi.current());
  return PlatformTelemetry(
    url: url,
    os: os,
    arch: arch,
    sender: IoTelemetrySender(userAgent: 'pi-desktop/$currentAppVersion ($os)'),
  );
}

/// `arm64`, `x64`, …: [abi]'s processor (`macos_arm64` → `arm64`).
String abiArch(Abi abi) => '$abi'.split('_').last;

/// What the app reports with ([platformTelemetry]).
class PlatformTelemetry {
  const PlatformTelemetry({
    required this.url,
    required this.os,
    required this.arch,
    required this.sender,
  });

  final Uri url;
  final String os;
  final String arch;
  final TelemetrySender sender;
}

/// A JSON POST over HTTPS.
class IoTelemetrySender implements TelemetrySender {
  IoTelemetrySender({
    this.userAgent = 'pi-desktop',
    this.timeout = const Duration(seconds: 15),
    HttpClient Function()? client,
  }) : _client = client ?? HttpClient.new;

  final String userAgent;
  final Duration timeout;
  final HttpClient Function() _client;

  @override
  Future<int> send(Uri url, Map<String, Object?> body) async {
    final client = _client()
      ..connectionTimeout = timeout
      ..userAgent = userAgent;
    try {
      final request = await client.postUrl(url).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }
}
