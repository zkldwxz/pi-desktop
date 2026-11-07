import '../../models/model_provider.dart';
import '../../models/model_providers.dart';
import '../../usage/usage_ledger.dart';
import '../../usage/usage_record.dart';

/// Record Pi's native provider calls in the existing Usage view. Calls through
/// the desktop account/custom-endpoint gateway are already recorded there.
void recordPiUsage(
  Map<String, Object?> message, {
  required ModelProviders providers,
  required String modelRef,
  required DateTime started,
  required Duration duration,
  Duration? firstToken,
  String? session,
  String? promptId,
  UsageClass requestClass = UsageClass.main,
}) {
  final resolved = providers.resolve(modelRef);
  final provider = resolved?.$1;
  final info = resolved?.$2;
  if (provider != null && info != null) {
    final effective = provider.speakingFor(info.id);
    if (effective.protocol.usesAccounts || effective.endpointUrl != null) {
      return;
    }
  }
  final raw = message['usage'];
  if (raw is! Map) return;
  int count(String key) => (raw[key] as num?)?.toInt() ?? 0;
  if (count('input') +
          count('output') +
          count('cacheRead') +
          count('cacheWrite') ==
      0) {
    return;
  }
  final native = parseModelRef(modelRef);
  UsageLedger.current.record(
    UsageCall(
      at: started,
      duration: duration,
      firstToken: firstToken,
      status: message['stopReason'] == 'error'
          ? 500
          : message['stopReason'] == 'aborted'
          ? 499
          : 200,
      provider:
          provider?.id ??
          'pi:${native?.provider ?? message['provider'] ?? 'native'}',
      providerName:
          provider?.name ??
          'PI ${native?.provider ?? message['provider'] ?? ''}',
      protocol: provider?.protocol.id ?? message['api'] as String?,
      model: info?.id ?? message['model'] as String? ?? native?.model ?? '',
      session: session,
      promptId: promptId,
      requestClass: requestClass,
      input: count('input'),
      output: count('output'),
      cacheRead: count('cacheRead'),
      cacheWrite: count('cacheWrite'),
      stopReason: message['stopReason'] as String?,
      error: message['errorMessage'] as String?,
    ),
  );
}
