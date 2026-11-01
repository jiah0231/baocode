import 'dart:async';

import 'package:bao_agent/bao_agent.dart';

import '../models/launch_environment.dart';
import '../models/model_provider.dart';
import '../models/model_runtime.dart';
import '../network/network_proxy.dart';
import 'learning_models.dart';

/// Reuses the existing provider/keychain, protocol adapter and usage ledger.
/// Called only after explicit consent; no CLI or agent engine is started.
Future<String> sendLearningRequest(
  ModelProvider provider,
  ProviderModel model,
  Map<String, Object?> body,
  LearningCancellation cancellation,
) async {
  final cancel = CancelToken();
  unawaited(cancellation.whenCancelled.then((_) => cancel.cancel()));
  if (cancellation.isCancelled) cancel.cancel();
  cancel.check();
  // Provider launch-only environment overrides are not inherited by this
  // tools-free request. The selected endpoint/auth and explicit headers remain.
  final environment = await cancel.guard(
    providerLaunchEnvironment(provider.copyWith(env: const {}), model.id),
  );
  cancel.check();
  final route = await cancel.guard(currentProxyRoute());
  final headers = <String, String>{};
  for (final line
      in (environment[ClaudeModelVariables.customHeadersVariable] ?? '').split(
        '\n',
      )) {
    final colon = line.indexOf(':');
    if (colon > 0) {
      headers[line.substring(0, colon).trim()] = line
          .substring(colon + 1)
          .trim();
    }
  }
  final client = AnthropicClient(
    ApiConfig(
      baseUrl: environment[ClaudeModelVariables.baseUrl] ?? '',
      apiKey: environment[ClaudeModelVariables.apiKey],
      authToken: environment[ClaudeModelVariables.authToken],
      headers: sanitizeHeaders(headers, provider.protocol),
      environment: {
        ...route.environment,
        ...environment,
        'no_proxy': ?environment['NO_PROXY'],
      },
      maxRetries: 0,
      idleTimeout: const Duration(seconds: 30),
    ),
  );
  var output = StringBuffer();
  try {
    await for (final event in client.stream(
      ModelRequest(
        body,
        headers: requestHints(
          environment,
          requestClass: 'auxiliary',
          agentType: 'learning',
        ),
      ),
      cancel: cancel,
    )) {
      cancel.check();
      switch (event) {
        case {'type': 'stream_restart'}:
          output = StringBuffer();
        case {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': final String text},
        }:
          output.write(text);
        case {
          'type': 'content_block_start',
          'content_block': {'type': 'tool_use'},
        }:
          throw const FormatException('Tools are not supported.');
      }
      if (output.length > 16000) throw const FormatException('Reply too long.');
    }
    cancel.check();
    return output.toString();
  } finally {
    cancel.cancel();
  }
}
