import 'package:flutter/foundation.dart';

import 'ide_color_theme_picker.dart';

/// A transactional gallery visit. Only Apply writes preferences. Requests
/// are serialized even for controllers that do not serialize their own loads.
class IdeThemePreviewSession extends ChangeNotifier {
  IdeThemePreviewSession(
    this.themes, {
    this.typographyPreset,
    this.persistTypographyPreset,
  }) : originalId = themes.colorThemeId,
       selectedId = themes.colorThemeId,
       originalTypographyPreset = typographyPreset?.value ?? false;

  /// Optional runtime override. Preview never changes editor.* preferences.
  final ValueNotifier<bool>? typographyPreset;
  final Future<void> Function(bool enabled)? persistTypographyPreset;
  final bool originalTypographyPreset;
  bool get typographyEnabled => typographyPreset?.value ?? false;

  void setTypographyEnabled(bool enabled) {
    if (_finished || busy || typographyPreset == null) return;
    typographyPreset!.value = enabled;
    _notify();
  }

  final IdeColorThemeController themes;
  final String originalId;
  String selectedId;
  Object? error;
  bool busy = false;
  bool _finished = false;
  bool _disposed = false;
  bool _applied = false;
  bool _typographyApplied = false;
  bool _cancelRequested = false;
  int _revision = 0;
  Future<void> _pending = Future.value();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> select(String id) async {
    if (_finished || busy) return;
    selectedId = id;
    error = null;
    final revision = ++_revision;
    _notify();
    await _enqueue(() async {
      if (revision != _revision) return;
      try {
        await themes.setColorTheme(id, preview: true);
        if (revision == _revision) _notify();
      } on Object catch (caught) {
        if (revision != _revision) return;
        error = caught;
        try {
          await themes.setColorTheme(originalId, preview: true);
        } on Object catch (restoreError) {
          error = restoreError;
        }
        _notify();
      }
    });
  }

  Future<bool> apply() async {
    if (_finished || busy) return false;
    busy = true;
    _cancelRequested = false;
    error = null;
    ++_revision;
    _notify();
    try {
      final selected = selectedId;
      final typography = typographyEnabled;
      await _enqueue(() async {
        await themes.setColorTheme(selected);
        _applied = true;
        try {
          if (typographyPreset != null) {
            await persistTypographyPreset?.call(typography);
            _typographyApplied = persistTypographyPreset != null;
          }
        } on Object {
          // A failed settings write must not leave half of Apply committed.
          await themes.setColorTheme(originalId);
          _applied = false;
          rethrow;
        }
      });
      _finished = true;
      return !_cancelRequested;
    } on Object catch (caught) {
      error = caught;
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> cancel() async {
    if (_finished) return;
    _finished = true;
    _cancelRequested = true;
    ++_revision;
    typographyPreset?.value = originalTypographyPreset;
    try {
      await _enqueue(() async {
        // Usually no settings were written. If a route was removed during
        // Apply, restore the settings as well as the visible preview.
        await themes.setColorTheme(originalId, preview: !_applied);
        if (_typographyApplied) {
          await persistTypographyPreset?.call(originalTypographyPreset);
        }
        typographyPreset?.value = originalTypographyPreset;
      });
    } on Object {
      _finished = false;
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
