import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../../theme/app_theme.dart';
import '../../platform/native_overlay_occlusion.dart';
import '../../theme/codicons.dart';
import '../file_service.dart';
import '../ide_button.dart';
import '../ide_spinning.dart';
import 'document_model.dart';
import 'document_preview_notices.dart';
import 'document_read.dart';
import 'document_strings.dart';
import 'office_preflight.dart';

/// A bounded snapshot shown by the local Office layout engines. The browser
/// host has no general-purpose file, network, JavaScript, or command bridge.
class FaithfulOfficePreview extends StatefulWidget {
  const FaithfulOfficePreview({
    super.key,
    required this.path,
    this.files,
    this.read,
    this.revision = 0,
    this.historical = false,
    this.onOpenInDefaultApp,
  });

  final String path;
  final IdeFileService? files;
  final Future<Uint8List> Function(String)? read;
  final int revision;
  final bool historical;
  final VoidCallback? onOpenInDefaultApp;

  @override
  State<FaithfulOfficePreview> createState() => _FaithfulOfficePreviewState();
}

void _validate(({String path, Uint8List bytes}) input) =>
    validateOfficePreview(path: input.path, bytes: input.bytes);

Future<void>? _preflightQueue;

Future<Uint8List> _readValidated({
  required String path,
  IdeFileService? files,
  Future<Uint8List> Function(String)? read,
  required Future<void> cancel,
  required bool Function() current,
}) {
  void check() {
    if (!current()) {
      throw const DocumentParseException(
        'Preview cancelled.',
        code: 'cancelled',
      );
    }
  }

  final previous = _preflightQueue;
  final released = Completer<void>();
  final gate = released.future;
  _preflightQueue = gate;
  Future<Uint8List> run() async {
    try {
      if (previous != null) await previous;
      check();
      final bytes = await readDocumentBytes(
        path,
        files: files,
        read: read,
        cancel: cancel,
      );
      check();
      await compute(_validate, (path: path, bytes: bytes));
      check();
      return bytes;
    } finally {
      if (identical(_preflightQueue, gate)) _preflightQueue = null;
      released.complete();
    }
  }

  return run();
}

/// One handler per engine, with independent preview lifetimes. A late callback
/// cannot load bytes into a newly selected document or another editor window.
abstract final class _OfficeHost {
  static const channel = MethodChannel('baocode/document_preview');
  static final clients = <int, _FaithfulOfficePreviewState>{};
  static int nextId = 0;
  static bool listening = false;

  static int register(_FaithfulOfficePreviewState state) {
    if (!listening) {
      listening = true;
      channel.setMethodCallHandler((call) async {
        if (call.method != 'event') return;
        final args = call.arguments;
        if (args is! Map || args['id'] is! int) return;
        clients[args['id']]?._event(args);
      });
      // No polling or self-scheduled frames. Reposition only on app frames,
      // after layout, including split resizing, UI zoom and tab visibility.
      WidgetsBinding.instance.addPersistentFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final client in clients.values.toList()) {
            client._frame();
          }
        });
      });
    }
    final id = ++nextId;
    clients[id] = state;
    return id;
  }

  static Future<void> invoke(String method, Map<String, Object?> args) =>
      channel.invokeMethod<void>(method, args);

  static void close(int id) {
    clients.remove(id);
    unawaited(invoke('dispose', {'id': id}).catchError((Object _) {}));
  }
}

class _FaithfulOfficePreviewState extends State<FaithfulOfficePreview> {
  final _surface = GlobalKey();
  int? _id;
  int _generation = 0;
  Completer<void>? _cancel;
  Timer? _deadline;
  Uint8List? _bytes;
  bool _opened = false;
  bool _ready = false;
  bool _loaded = false;
  Object? _error;
  Map<String, Object?>? _bounds;
  String? _theme;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(FaithfulOfficePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.files != widget.files ||
        oldWidget.read != widget.read ||
        oldWidget.revision != widget.revision ||
        oldWidget.historical != widget.historical) {
      unawaited(_load());
    }
  }

  void _close() {
    _deadline?.cancel();
    _deadline = null;
    _cancel?.complete();
    _cancel = null;
    final id = _id;
    _id = null;
    if (id != null) _OfficeHost.close(id);
    _bytes = null;
    _opened = false;
    _ready = false;
    _loaded = false;
    _bounds = null;
    _theme = null;
  }

  @override
  void dispose() {
    _generation++;
    _close();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _close();
    setState(() => _error = null);
    if (widget.historical) return;
    final cancel = _cancel = Completer<void>();
    try {
      final bytes = await _readValidated(
        path: widget.path,
        files: widget.files,
        read: widget.read,
        cancel: cancel.future,
        current: () => mounted && generation == _generation,
      );
      if (!mounted || generation != _generation) return;
      _bytes = bytes;
      _id = _OfficeHost.register(this);
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) => _frame());
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = error);
    }
  }

  String get _format => nativeDocumentFormat(widget.path)!;

  void _failed([Object? error]) {
    if (!mounted) return;
    _close();
    setState(
      () => _error =
          (error is PlatformException && error.code == 'limit'
              ? const DocumentParseException(
                  'Close another document preview and try again.',
                  code: 'previewLimit',
                )
              : error) ??
          const DocumentParseException(
            'The offline document renderer could not open this file.',
            code: 'renderer',
          ),
    );
  }

  void _event(Map<dynamic, dynamic> event) {
    if (!mounted || event['id'] != _id) return;
    switch (event['type']) {
      case 'ready':
        if (_ready) return;
        _ready = true;
        _sendTheme();
        _send({
          'type': 'load',
          'kind': _format,
          'name': path.basename(widget.path.replaceAll('\\', '/')),
          'url': '/document',
        });
      case 'loaded':
        _deadline?.cancel();
        setState(() => _loaded = true);
      case 'error':
        _failed();
    }
  }

  void _send(Map<String, Object?> value) {
    final id = _id;
    if (id == null || !_ready) return;
    unawaited(
      _OfficeHost.invoke('postMessage', {
        'id': id,
        'json': jsonEncode(value),
      }).catchError((Object error) {
        if (_id == id) _failed(error);
      }),
    );
  }

  void _sendTheme() {
    String color(Color value) =>
        '#${(value.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
    final theme = {
      'background': color(AppColors.code),
      'foreground': color(AppColors.text),
      'border': color(AppColors.partBorder),
      'surface': color(AppColors.surface),
      'accent': color(AppColors.accent),
      'muted': color(AppColors.textMuted),
      'toolbarHover': color(
        Color.alphaBlend(AppColors.hover, AppColors.surface),
      ),
      'toolbarActive': color(
        Color.alphaBlend(
          AppColors.accent.withValues(alpha: .18),
          AppColors.surface,
        ),
      ),
      'sourceUrl': DocumentPreviewNotices.source.toString(),
      'dark': AppColors.surface.computeLuminance() < .5,
    };
    final encoded = jsonEncode(theme);
    if (_theme == encoded || !_ready) return;
    _theme = encoded;
    _send({'type': 'theme', 'theme': theme});
  }

  void _frame() {
    final id = _id;
    if (!mounted || id == null) return;
    final box = _surface.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final view = View.of(context);
    final topLeft = box.localToGlobal(Offset.zero);
    final bottomRight = box.localToGlobal(box.size.bottomRight(Offset.zero));
    final authoredRect = Rect.fromPoints(topLeft, bottomRight);
    if (!authoredRect.isFinite) return;
    final scale = view.devicePixelRatio;
    final viewport = Offset.zero & (view.physicalSize / scale);
    final rect = authoredRect.intersect(viewport);
    var visible =
        _loaded &&
        !rect.isEmpty &&
        rect == authoredRect &&
        TickerMode.valuesOf(context).enabled &&
        !NativeOverlayOcclusion.coversView(view.viewId);
    if (visible) {
      // A native child must not cover Flutter dialogs/menus or inactive tabs.
      // Hit tests detect offstage/covered surfaces without a permanent ticker.
      for (final x in [.02, .25, .5, .75, .98]) {
        for (final y in [.02, .25, .5, .75, .98]) {
          final result = HitTestResult();
          WidgetsBinding.instance.hitTestInView(
            result,
            Offset(rect.left + rect.width * x, rect.top + rect.height * y),
            view.viewId,
          );
          if (!result.path.any((entry) => identical(entry.target, box))) {
            visible = false;
            break;
          }
        }
        if (!visible) break;
      }
    }
    final bounds = <String, Object?>{
      'id': id,
      'x': rect.left.clamp(0, viewport.width) * scale,
      'y': rect.top.clamp(0, viewport.height) * scale,
      'width': rect.isEmpty ? 0.0 : rect.width * scale,
      'height': rect.isEmpty ? 0.0 : rect.height * scale,
      'visible': visible,
    };
    if (!_opened) {
      final bytes = _bytes;
      if (bytes == null || rect.isEmpty) return;
      _opened = true;
      _bytes = null;
      _bounds = bounds;
      _deadline = Timer(const Duration(seconds: 45), () {
        if (_id == id && !_loaded) _failed();
      });
      unawaited(
        _OfficeHost.invoke('open', {
          ...bounds,
          'viewId': view.viewId,
          'bytes': bytes,
          'format': _format,
        }).catchError((Object error) {
          if (_id == id) _failed(error);
        }),
      );
    } else if (jsonEncode(_bounds) != jsonEncode(bounds)) {
      _bounds = bounds;
      unawaited(
        _OfficeHost.invoke('updateBounds', bounds).catchError((Object error) {
          if (_id == id) _failed(error);
        }),
      );
    }
    _sendTheme();
  }

  @override
  Widget build(BuildContext context) {
    final strings = DocumentStrings(context);
    return ColoredBox(
      color: AppColors.code,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: AppColors.text, fontSize: 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(bottom: BorderSide(color: AppColors.partBorder)),
              ),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IdeButton(
                    label: strings.reload,
                    icon: Codicons.refresh,
                    secondary: true,
                    onPressed: () => unawaited(_load()),
                  ),
                  if (widget.onOpenInDefaultApp != null)
                    IdeButton(
                      label: strings.openExternal,
                      icon: Codicons.linkExternal,
                      secondary: true,
                      onPressed: widget.onOpenInDefaultApp,
                    ),
                ],
              ),
            ),
            Expanded(child: _body(strings)),
          ],
        ),
      ),
    );
  }

  Widget _body(DocumentStrings strings) {
    final error = _error;
    if (widget.historical || error != null) {
      final message = widget.historical
          ? strings.revision
          : error is DocumentParseException
          ? strings.parseError(error.code, error.message)
          : strings.rendererError;
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              if (!widget.historical) ...[
                const SizedBox(height: 14),
                IdeButton(
                  label: strings.retry,
                  onPressed: () => unawaited(_load()),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Listener(
      key: _surface,
      behavior: HitTestBehavior.opaque,
      child: SizedBox.expand(
        child: _loaded
            ? const SizedBox.shrink()
            : Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IdeSpinning(
                      Icon(Codicons.loading, color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 10),
                    Text(strings.loading),
                  ],
                ),
              ),
      ),
    );
  }
}
