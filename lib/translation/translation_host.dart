import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../platform/app_platform.dart';
import '../settings/user_settings.dart';

/// One explicitly requested selection snapshot, including a guarded temporary
/// clipboard capture where direct accessibility selection is unavailable.
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
/// Configures metadata-only selection discovery; no clipboard listener,
/// translation persistence or network access.
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
  static const selectionActionKey = 'translation.selectionAction.enabled';
  static const clipboardFallbackKey = 'translation.clipboardFallback';
  final MethodChannel _channel;
  final bool supported;
  final int? engineId;

  /// Enabled only when the app mounts a ViewCollection for native tool views.
  bool panelEnabled;
  UserSettings? _settings;
  bool _started = false;
  bool _paused = false;
  String? _requested;
  (bool, bool, bool)? _requestedConfiguration;
  bool _dark = true;
  Future<void> _queue = Future<void>.value();
  bool? hotkeyTaken;
  bool? selectionActionTaken;
  String? lastCaptureWarning;
  void Function(TranslationCapture capture)? onPressed;

  int? panelViewId;
  bool panelShown = false;
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
    panelShown = false;
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
    if (generation != panelGeneration || panelCapture == null || panelShown) {
      return;
    }
    final requestId = panelCapture!.requestId;
    try {
      final shown = await _channel.invokeMethod<bool>('showPanel', {
        'requestId': ?requestId,
      });
      if (generation != panelGeneration || panelCapture == null) return;
      if (shown == true) {
        panelShown = true;
        notifyListeners();
      } else {
        _clearPanel();
      }
    } on Object {
      if (generation == panelGeneration) _clearPanel();
    }
  }

  void _clearPanel() {
    panelGeneration++;
    panelCapture = null;
    panelShown = false;
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

  bool get selectionActionEnabled => _settings?[selectionActionKey] != false;
  bool get clipboardFallback => _settings?[clipboardFallbackKey] != false;

  /// Updates native button colors independently of hotkey registration.
  Future<void> configureAppearance(bool dark) {
    _dark = dark;
    return _sync();
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
      if (call case MethodCall(
        method: 'captureWarning',
        arguments: {'status': 'clipboardRestoreFailed'},
      )) {
        // Late clipboard cleanup failures must not reopen a stale panel or
        // activate the workspace. Show this in any current/next panel/settings.
        lastCaptureWarning = 'clipboardRestoreFailed';
        notifyListeners();
      }
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
    if (!supported || (!_started && _requested == null)) return _queue;
    final running = _started && !_paused;
    final wanted = running ? hotkey : '';
    final configuration = (
      running && selectionActionEnabled,
      running && clipboardFallback,
      _dark,
    );
    final register = _requested != wanted;
    final configure = _requestedConfiguration != configuration;
    if (!register && !configure) return _queue;
    _requested = wanted;
    _requestedConfiguration = configuration;
    if (register) hotkeyTaken = null;
    if (configure) selectionActionTaken = null;
    notifyListeners();
    return _queue = _queue.then((_) async {
      if (configure) {
        bool? installed;
        try {
          final reply = await _channel.invokeMethod<Object?>('configure', {
            'selectionAction': configuration.$1,
            'clipboardFallback': configuration.$2,
            'dark': configuration.$3,
          });
          installed = switch (reply) {
            {'selectionAction': final bool enabled} => enabled,
            final bool enabled => enabled,
            _ => null,
          };
        } on MissingPluginException {
          // Older hosts still support their hotkey and modal translation.
        } on PlatformException {
          // Configuration failure must not prevent hotkey registration.
          installed = false;
        }
        if (_requestedConfiguration == configuration) {
          selectionActionTaken = configuration.$1 ? installed : null;
          notifyListeners();
        }
      }
      if (!register) return;
      bool? taken;
      try {
        taken = await _channel.invokeMethod<bool>('setHotkey', wanted);
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
