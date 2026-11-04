import 'package:flutter/foundation.dart';

import 'ide_color_theme_picker.dart';

/// A transactional gallery visit. Only Apply writes preferences. Requests
/// are serialized even for controllers that do not serialize their own loads.
class IdeThemePreviewSession extends ChangeNotifier {
  IdeThemePreviewSession(this.themes)
    : originalId = themes.colorThemeId,
      selectedId = themes.colorThemeId;

  final IdeColorThemeController themes;
  final String originalId;
  String selectedId;
  Object? error;
  bool busy = false;
  bool _finished = false;
  bool _disposed = false;
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
    error = null;
    ++_revision;
    _notify();
    try {
      await _enqueue(() => themes.setColorTheme(selectedId));
      _finished = true;
      return true;
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
    ++_revision;
    try {
      await _enqueue(() => themes.setColorTheme(originalId, preview: true));
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
