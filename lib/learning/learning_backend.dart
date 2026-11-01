import 'dart:async';
import 'dart:convert';

import '../models/model_provider.dart';
import '../models/model_providers.dart';
import 'learning_models.dart';
import 'learning_preferences.dart';
import 'learning_transport_stub.dart'
    if (dart.library.io) 'learning_transport_io.dart'
    as platform;

/// No engine, file access, tool dispatch, or conversation history is exposed to
/// this boundary. Tests replace it without opening a connection.
typedef LearningTransport = Future<String> Function(
  ModelProvider provider,
  ProviderModel model,
  Map<String, Object?> body,
  LearningCancellation cancellation,
);

class LearningModelChoice {
  const LearningModelChoice({required this.ref, required this.label});
  final String ref;
  final String label;
}

class LearningBackendException implements Exception {
  const LearningBackendException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LearningBackend implements LearningGenerator {
  LearningBackend({required this.preferences, LearningTransport? transport})
    : _transport = transport ?? platform.sendLearningRequest;

  final LearningPreferences preferences;
  final LearningTransport _transport;

  static List<LearningModelChoice> choices(ModelProviders providers) => [
    for (final provider in providers.enabled)
      for (final model in provider.enabledModels)
        if (!model.missing && !model.kind.generatesImages)
          LearningModelChoice(
            ref: modelRef(provider.id, model.id),
            label: '${provider.name} · ${model.displayName}',
          ),
  ];

  static String? modelLabel(String? ref, ModelProviders providers) =>
      switch (LearningPreferences.exactModel(providers, ref)) {
        (final provider, final model) =>
          '${provider.name} · ${model.displayName}',
        null => null,
      };

  @override
  Future<Map<String, Object?>> generate(
    LearningRequest request,
    LearningCancellation cancellation,
  ) async {
    if (!preferences.enabled || cancellation.isCancelled) {
      throw const LearningBackendException(
        'Learning is paused or not configured.',
      );
    }
    final selected = preferences.selection;
    if (selected == null) {
      throw const LearningBackendException(
        'Choose an available learning model.',
      );
    }
    final ref = preferences.modelRef;
    final (provider, model) = selected;
    final context = jsonEncode(request.toJson());
    if (context.length > 18000 ||
        request.maxOutputTokens < 1 ||
        request.maxOutputTokens > 1200) {
      throw const LearningBackendException(
        'The learning context exceeds its safe limit.',
      );
    }
    final body = <String, Object?>{
      'model': model.id,
      'max_tokens': request.maxOutputTokens,
      'stream': true,
      'system': request.systemInstruction,
      'messages': [
        {'role': 'user', 'content': context},
      ],
      // Explicitly no tools, tool_choice, thinking, attachments or metadata.
    };
    final local = LearningCancellation();
    void checkPreferences() {
      if (!preferences.enabled || preferences.modelRef != ref) local.cancel();
    }

    preferences.addListener(checkPreferences);
    unawaited(cancellation.whenCancelled.then((_) => local.cancel()));
    final timeout = Timer(const Duration(seconds: 45), local.cancel);
    try {
      // Cancellation updates the UI immediately, but must not release the
      // controller's single-flight slot until the HTTP transport has actually
      // torn down. Racing this future against cancellation permits paid
      // requests to overlap after a rapid pause/resume or model switch.
      final text = await _transport(provider, model, body, local);
      if (local.isCancelled || cancellation.isCancelled) {
        throw const LearningBackendException(
          'Learning was paused or the request expired.',
        );
      }
      if (text.length > 16000) {
        throw const LearningBackendException(
          'The learning reply was too long.',
        );
      }
      final json = jsonDecode(text.trim());
      if (json is! Map<String, dynamic>) {
        throw const LearningBackendException(
          'The model did not return a lesson card.',
        );
      }
      return Map<String, Object?>.from(json);
    } on LearningBackendException {
      rethrow;
    } on Object {
      // Provider errors may echo prompts, credentials, URLs, or raw bodies.
      throw const LearningBackendException(
        'The learning model could not respond. Check its configuration and try again.',
      );
    } finally {
      timeout.cancel();
      preferences.removeListener(checkPreferences);
      local.cancel();
    }
  }
}
