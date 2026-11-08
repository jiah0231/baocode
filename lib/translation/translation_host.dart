import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../platform/app_platform.dart';
import '../settings/user_settings.dart';

/// A single explicitly requested native selection snapshot. Never clipboard text.
@immutable
class TranslationCapture {
  const TranslationCapture({
    this.text = '',
    this.status = 'noSelection',
    this.inApp = false,
    this.requestId,
  });
  final String text;
  final String status;
  final bool inApp;
  final int? requestId;

  factory TranslationCapture.fromJson(Object? value) {
    if (value is! Map) return const TranslationCapture(status: 'unsupported');
    final text = value['text'];
    final status = value['status'];
    if (text is String && text.length > 8000) {
      return TranslationCapture(
        status: 'tooLong',
        inApp: value['self'] == true,
        requestId: value['requestId'] is int ? value['requestId'] as int : null,
      );
    }
    return TranslationCapture(
      text: status == 'ok' && text is String ? text : '',
      status: status is String ? status : 'unsupported',
      inApp: value['self'] == true,
      requestId: value['requestId'] is int ? value['requestId'] as int : null,
    );
  }
}

/// One native hotkey for the whole process, owned by the main workbench.
/// No clipboard listener, selection poller, persistence or network access.
class TranslationHost extends ChangeNotifier {
  TranslationHost({
    MethodChannel? channel,
    bool? supported,
    this.engineId,
    this.panelEnabled = true,
  }) : _channel = channel ?? const MethodChannel('baocode/translation'),
       supported = supported ?? AppPlatform.isWindows;

  static final instance = TranslationHost(panelEnabled: false);
  static const hotkeyKey = 'translation.globalHotkey';
  static const defaultHotkey = 'ctrl+alt+y';
  final MethodChannel _channel;
  final bool supported;
  final int? engineId;

  /// Enabled only when the app mounts a ViewCollection for native tool views.
  bool panelEnabled;
  UserSettings? _settings;
  bool _started = false;
  bool _paused = false;
  String? _requested;
  Future<void> _queue = Future<void>.value();
  bool? hotkeyTaken;
  void Function(TranslationCapture capture)? onPressed;

  int? panelViewId;
  TranslationCapture? panelCapture;
  VoidCallback? panelModelSettings;
  VoidCallback? defaultModelSettings;
  int panelGeneration = 0;
  Future<int?>? _creating;

  /// False means this platform cannot create a panel; only then use a modal.
  Future<bool> openPanel(
    TranslationCapture capture, {
    VoidCallback? onModelSettings,
  }) async {
    if (!supported || !panelEnabled) return false;
    final generation = ++panelGeneration;
    panelCapture = null;
    panelModelSettings = null;
    notifyListeners();
    // Hide old pixels before asynchronously preparing a different selection.
    if (panelViewId != null) await _hideNative();
    int? id;
    try {
      id =
          panelViewId ??
          await (_creating ??= _channel.invokeMethod<int>('createPanel', {
            'engineId':
                engineId ?? WidgetsBinding.instance.platformDispatcher.engineId,
          }));
    } on MissingPluginException {
      return generation != panelGeneration;
    } on PlatformException {
      return generation != panelGeneration;
    } finally {
      _creating = null;
    }
    if (id == null || id < 0) return generation != panelGeneration;
    panelViewId = id;
    if (generation != panelGeneration) return true;
    panelCapture = capture;
    panelModelSettings = onModelSettings ?? defaultModelSettings;
    notifyListeners();
    return true;
  }

  /// Called by the panel after its new content has been laid out and painted.
  Future<void> panelRendered(int generation) async {
    if (generation != panelGeneration || panelCapture == null) return;
    final requestId = panelCapture!.requestId;
    try {
      final shown = await _channel.invokeMethod<bool>('showPanel', {
        'requestId': ?requestId,
      });
      if (shown != true && generation == panelGeneration) _clearPanel();
    } on Object {
      if (generation == panelGeneration) _clearPanel();
    }
  }

  void _clearPanel() {
    panelGeneration++;
    panelCapture = null;
    panelModelSettings = null;
    notifyListeners();
  }

  Future<void> _hideNative() async {
    try {
      await _channel.invokeMethod<void>('hidePanel');
    } on MissingPluginException {
      // Older hosts use the modal fallback.
    } on PlatformException {
      // Contents have already been discarded locally.
    }
  }

  Future<void> hidePanel() async {
    _clearPanel();
    if (panelViewId != null) await _hideNative();
  }

  String get hotkey => switch (_settings?[hotkeyKey]) {
    final String value => value,
    _ => defaultHotkey,
  };

  void start(UserSettings? settings) {
    if (_started) return;
    _started = true;
    _settings = settings;
    settings?.addListener(_changed);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'panelHidden') {
        final args = call.arguments;
        final hiddenId = args is Map ? args['requestId'] : null;
        if (panelCapture != null &&
            (panelCapture!.requestId == null ||
                panelCapture!.requestId == hiddenId)) {
          _clearPanel();
        }
      }
      if (_started && !_paused && call.method == 'pressed') {
        onPressed?.call(TranslationCapture.fromJson(call.arguments));
      }
      return null;
    });
    _changed();
  }

  void _changed() => unawaited(_sync());

  Future<void> _sync() {
    final wanted = supported && _started && !_paused ? hotkey : '';
    if (_requested == wanted) return _queue;
    _requested = wanted;
    hotkeyTaken = null;
    notifyListeners();
    return _queue = _queue.then((_) async {
      bool? taken;
      try {
        taken = supported
            ? await _channel.invokeMethod<bool>('setHotkey', wanted)
            : null;
      } on MissingPluginException {
        taken = null;
      } on PlatformException {
        taken = false;
      }
      if (_requested == wanted) {
        hotkeyTaken = taken;
        notifyListeners();
      }
    });
  }

  Future<void> pause() {
    _paused = true;
    return _sync();
  }

  Future<void> resume() {
    _paused = false;
    return _sync();
  }

  void stop() {
    _started = false;
    _settings?.removeListener(_changed);
    _settings = null;
    onPressed = null;
    defaultModelSettings = null;
    unawaited(hidePanel());
    _channel.setMethodCallHandler(null);
    unawaited(_sync());
  }
}
