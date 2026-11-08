import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';
import '../settings/user_settings.dart';

/// A single explicitly requested native selection snapshot. Never clipboard text.
@immutable
class TranslationCapture {
  const TranslationCapture({
    this.text = '',
    this.status = 'noSelection',
    this.inApp = false,
  });
  final String text;
  final String status;
  final bool inApp;

  factory TranslationCapture.fromJson(Object? value) {
    if (value is! Map) return const TranslationCapture(status: 'unsupported');
    final text = value['text'];
    final status = value['status'];
    if (text is String && text.length > 8000) {
      return TranslationCapture(
        status: 'tooLong',
        inApp: value['self'] == true,
      );
    }
    return TranslationCapture(
      text: status == 'ok' && text is String ? text : '',
      status: status is String ? status : 'unsupported',
      inApp: value['self'] == true,
    );
  }
}

/// One native hotkey for the whole process, owned by the main workbench.
/// No clipboard listener, selection poller, persistence or network access.
class TranslationHost extends ChangeNotifier {
  TranslationHost({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel('baocode/translation'),
      supported = supported ?? AppPlatform.isWindows;

  static final instance = TranslationHost();
  static const hotkeyKey = 'translation.globalHotkey';
  static const defaultHotkey = 'ctrl+alt+y';
  final MethodChannel _channel;
  final bool supported;
  UserSettings? _settings;
  bool _started = false;
  bool _paused = false;
  String? _requested;
  Future<void> _queue = Future<void>.value();
  bool? hotkeyTaken;
  void Function(TranslationCapture capture)? onPressed;

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
    _channel.setMethodCallHandler(null);
    unawaited(_sync());
  }
}
