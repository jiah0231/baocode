import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/model_provider.dart';
import '../models/model_providers.dart';
import '../settings/user_settings.dart';
import 'learning_models.dart';

enum LearningPace { calm, balanced }

/// Only preferences are persisted. Evidence and generated lessons stay in memory.
class LearningPreferences extends ChangeNotifier {
  LearningPreferences({
    required this._read,
    required this._write,
    Listenable? changes,
    ModelProviders? providers,
    this.scope = '',
  }) : _changes = changes,
       providers = providers ?? ModelProviders.current {
    changes?.addListener(_changed);
    this.providers.addListener(_changed);
  }

  factory LearningPreferences.settings(
    UserSettings settings, {
    ModelProviders? providers,
    String scope = '',
  }) => LearningPreferences(
    read: (key) => settings[key],
    write: settings.update,
    changes: settings,
    providers: providers,
    scope: scope,
  );

  factory LearningPreferences.memory({
    ModelProviders? providers,
    String scope = '',
  }) {
    final values = <String, Object?>{};
    return LearningPreferences(
      read: (key) => values[key],
      write: (key, value) async {
        values[key] = value;
      },
      providers: providers,
      scope: scope,
    );
  }

  static const settingKey = 'learning.sidebar';
  final Object? Function(String key) _read;
  final Future<void> Function(String key, Object? value) _write;
  final Listenable? _changes;
  final ModelProviders providers;
  final String scope;
  String get _scopeDigest => sha256.convert(utf8.encode(scope)).toString();
  Future<void> _writes = Future<void>.value();
  bool _disposed = false;

  Map<String, Object?> get _value => switch (_read(settingKey)) {
    final Map value => Map<String, Object?>.fromEntries([
      for (final entry in value.entries)
        if (entry.key is String) MapEntry(entry.key as String, entry.value),
    ]),
    _ => const {},
  };

  String? get modelRef => switch (_value['model']) {
    final String value when parseModelRef(value) != null => value,
    _ => null,
  };

  /// Consent is bound to the exact endpoint/model configuration. A removed,
  /// disabled or changed provider cannot silently redirect background evidence.
  bool get enabled =>
      _value['enabled'] == true &&
      _value['consentVersion'] == 1 &&
      _value['scope'] == _scopeDigest &&
      selection != null &&
      _value['fingerprint'] == _fingerprint(modelRef!);

  (ModelProvider, ProviderModel)? get selection =>
      exactModel(providers, modelRef);

  LearningDepth get depth => LearningDepth.values.firstWhere(
    (value) => value.name == _value['depth'],
    orElse: () => LearningDepth.values.first,
  );

  LearningPace get pace => _value['pace'] == LearningPace.balanced.name
      ? LearningPace.balanced
      : LearningPace.calm;
  Duration get interval =>
      Duration(seconds: pace == LearningPace.calm ? 24 : 12);

  /// Call only from the explicit consent action after showing the chosen
  /// provider/model, contextual code disclosure, and possible usage costs.
  Future<void> configure({required String modelRef, required bool consent}) {
    if (!consent || exactModel(providers, modelRef) == null) {
      return Future.error(
        ArgumentError('Choose an available model and confirm sharing.'),
      );
    }
    final fingerprint = _fingerprint(modelRef);
    return _update({
      'model': modelRef,
      'enabled': true,
      'consentVersion': 1,
      'scope': _scopeDigest,
      'fingerprint': fingerprint,
    });
  }

  String get configurationToken =>
      jsonEncode([enabled, modelRef, depth.name, pace.name]);

  Future<void> disable() => _update({'enabled': false});
  Future<void> setDepth(LearningDepth depth) => _update({'depth': depth.name});
  Future<void> setPace(LearningPace pace) => _update({'pace': pace.name});

  Future<void> _update(Map<String, Object?> patch) {
    final operation = _writes.then((_) async {
      await _write(settingKey, {..._value, ...patch});
      _changed();
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  String? _fingerprint(String ref) {
    final selected = exactModel(providers, ref);
    if (selected == null) return null;
    final (provider, model) = selected;
    // A digest, not a second copy of provider headers/environment in settings.
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'provider': provider.toJson(),
              'model': model.toJson(),
            }),
          ),
        )
        .toString();
  }

  static (ModelProvider, ProviderModel)? exactModel(
    ModelProviders providers,
    String? ref,
  ) {
    final parsed = parseModelRef(ref);
    if (parsed == null) return null;
    final provider = providers.provider(parsed.provider);
    if (provider == null || !provider.enabled) return null;
    final model = provider.model(parsed.model);
    if (model == null ||
        !model.enabled ||
        model.missing ||
        model.kind.generatesImages) {
      return null;
    }
    return (provider, model);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _changes?.removeListener(_changed);
    providers.removeListener(_changed);
    super.dispose();
  }
}
