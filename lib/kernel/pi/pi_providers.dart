import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/launch_environment.dart';
import '../../models/model_provider.dart';
import '../../models/model_providers.dart';
import '../../models/model_runtime.dart';
import '../../models/upstream.dart';

class PiModelBinding {
  const PiModelBinding({
    required this.ref,
    required this.provider,
    required this.model,
  });
  final String ref;
  final String provider;
  final String model;
}

class PiProviderSetup {
  const PiProviderSetup(this.environment, this.bindings);
  final Map<String, String> environment;
  final List<PiModelBinding> bindings;
}

/// Share the existing Models settings and keychain with Pi. Standard APIs go
/// through Pi's native adapters; account routing and custom complete endpoints
/// use the application's existing gateway.
Future<PiProviderSetup> piProviderSetup(ModelProviders providers) async {
  final environment = <String, String>{};
  final configured = <Map<String, Object?>>[];
  final bindings = <PiModelBinding>[];
  for (final provider in providers.enabled) {
    final key = await providers.key(provider.id);
    environment.addAll(provider.env);
    for (final info in provider.enabledModels) {
      final effective = provider.speakingFor(info.id);
      final protocol = effective.protocol;
      final String baseUrl;
      final String api;
      final String credential;
      var bearer =
          protocol != ProviderProtocol.anthropic ||
          provider.auth == ProviderAuth.bearer;
      var headers = provider.headers;
      if (protocol.usesAccounts || effective.endpointUrl != null) {
        final env = await providerLaunchEnvironment(effective, info.id);
        baseUrl = env[ClaudeModelVariables.baseUrl]!;
        credential = env[ClaudeModelVariables.authToken]?.isNotEmpty == true
            ? env[ClaudeModelVariables.authToken]!
            : env[ClaudeModelVariables.apiKey] ?? '';
        api = 'anthropic-messages';
        bearer = env[ClaudeModelVariables.authToken]?.isNotEmpty == true;
        headers = const {};
        if (env['NO_PROXY'] case final bypass?) {
          environment['NO_PROXY'] = bypass;
        }
      } else {
        api = switch (protocol) {
          ProviderProtocol.anthropic => 'anthropic-messages',
          ProviderProtocol.openaiChat => 'openai-completions',
          ProviderProtocol.openaiResponses => 'openai-responses',
          ProviderProtocol.codex => throw StateError(
            'Account gateway was not configured',
          ),
        };
        baseUrl = protocol == ProviderProtocol.anthropic
            ? UpstreamUrls.anthropicBase(provider.baseUrl) ?? provider.baseUrl
            : UpstreamUrls.openaiBase(provider.baseUrl) ?? provider.baseUrl;
        credential = key ?? '';
      }
      final ref = modelRef(provider.id, info.id);
      final id =
          'desktop-${sha256.convert(utf8.encode(ref)).toString().substring(0, 20)}';
      final keyVariable = 'PI_DESKTOP_KEY_${configured.length}';
      // Pi accepts keyless local providers with a nonempty placeholder; it is
      // confined to the endpoint explicitly configured by the user.
      environment[keyVariable] = credential.isEmpty
          ? 'pi-desktop-local'
          : credential;
      configured.add({
        'id': id,
        'name': provider.name,
        'api': api,
        'baseUrl': baseUrl,
        'authHeader': bearer,
        'headers': headers,
        'keyVariable': keyVariable,
        'models': [
          {
            'type': 'chat',
            'id': info.id,
            'name': info.displayName,
            'reasoning': info.effortLevels.any((level) => level != 'none'),
            'input': ['text', if (info.images) 'image'],
            'contextWindow': info.contextWindow ?? ProviderModel.defaultContext,
            'maxTokens': 16384,
            'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
          },
        ],
      });
      bindings.add(PiModelBinding(ref: ref, provider: id, model: info.id));
    }
  }
  environment['PI_DESKTOP_PROVIDERS'] = jsonEncode(configured);
  return PiProviderSetup(environment, bindings);
}
