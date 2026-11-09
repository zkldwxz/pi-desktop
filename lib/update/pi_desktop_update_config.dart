import 'dart:convert';

import 'update_manifest.dart';

/// Configuration must be supplied for each pi-desktop release. There is no
/// fallback to pi-desktop's feed or signing key.
class PiDesktopUpdateConfig {
  const PiDesktopUpdateConfig._(this.manifestUrl, this.publicKey, this.policy);

  static const urlVariable = 'PI_DESKTOP_UPDATE_URL';
  static const keyVariable = 'PI_DESKTOP_UPDATE_PUBLIC_KEY';
  static const localhostVariable = 'PI_DESKTOP_UPDATE_ALLOW_LOCALHOST';
  static const originsVariable = 'PI_DESKTOP_UPDATE_ALLOWED_ORIGINS';

  static const _buildUrl = String.fromEnvironment(urlVariable);
  static const _buildKey = String.fromEnvironment(keyVariable);
  static const _buildLocalhost = String.fromEnvironment(localhostVariable);
  static const _buildOrigins = String.fromEnvironment(originsVariable);

  final Uri manifestUrl;
  final String publicKey;
  final UpdateUrlPolicy policy;

  /// Runtime environment values override compile-time values, including when
  /// explicitly empty. HTTP is restricted to loopback and requires opt-in.
  static PiDesktopUpdateConfig? fromEnvironment(
    Map<String, String> environment,
  ) {
    final url = (environment[urlVariable] ?? _buildUrl).trim();
    final key = (environment[keyVariable] ?? _buildKey).trim();
    final allowLocalhost =
        (environment[localhostVariable] ?? _buildLocalhost).trim() == 'true';
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !uri.hasScheme) {
      return null;
    }
    final loopback =
        uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1';
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' && allowLocalhost && loopback)) {
      return null;
    }
    try {
      final bytes = base64.decode(key);
      if (bytes.length != 32) return null;
    } on FormatException {
      return null;
    }
    final origins = <String>{uri.origin};
    final configuredOrigins = environment[originsVariable] ?? _buildOrigins;
    for (final entry in configuredOrigins.split(',')) {
      final value = entry.trim();
      if (value.isEmpty) continue;
      final origin = Uri.tryParse(value);
      if (origin == null ||
          origin.host.isEmpty ||
          origin.userInfo.isNotEmpty ||
          origin.hasQuery ||
          origin.hasFragment ||
          (origin.path.isNotEmpty && origin.path != '/')) {
        return null;
      }
      final loopback =
          origin.host == 'localhost' ||
          origin.host == '127.0.0.1' ||
          origin.host == '::1';
      if (origin.scheme != 'https' &&
          !(origin.scheme == 'http' && allowLocalhost && loopback)) {
        return null;
      }
      origins.add(origin.origin);
    }
    return PiDesktopUpdateConfig._(
      uri,
      key,
      UpdateUrlPolicy.exactOrigins(origins, allowLocalhost: allowLocalhost),
    );
  }
}
