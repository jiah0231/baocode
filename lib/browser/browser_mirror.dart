import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ide/ide_button.dart';
import '../ide/ide_commands.dart' show ideUsesMacKeys;
import '../ide/ide_hover.dart';
import '../ide/ide_menu.dart';
import '../l10n/l10n.dart';
import '../settings/settings_dialog.dart' show SettingsOpener, SettingsSection;
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import 'browser_agent_control.dart';
import 'browser_bridge.dart';
import 'browser_frame_flow.dart';
import 'browser_keys.dart';
import 'browser_panel_controller.dart';
import 'browser_toolbar.dart';
import 'browser_tools.dart';

/// A pinned tab of the user's Chrome, shared with BaoCode. Its page is shown as
/// the browser draws it (its screencast while the tab is in front, which
/// stops behind another; screenshots then), and what the user does here is
/// sent to it: the pointer's, the keyboard's, an input method's.
class BrowserMirror extends StatefulWidget {
  const BrowserMirror({
    super.key,
    this.sessionId,
    this.initialTab,
    this.onSelectionChanged,
  });

  final String? sessionId;
  final BrowserTab? initialTab;
  final ValueChanged<BrowserTab>? onSelectionChanged;

  @override
  State<BrowserMirror> createState() => _BrowserMirrorState();
}

class _BrowserMirrorState extends State<BrowserMirror>
    with TextInputClient, WidgetsBindingObserver {
  BrowserBridge get _bridge => BrowserBridge.instance;

  late final BrowserPanelController _panel;
  final _control = BrowserAgentControl.instance;
  late final BrowserFrameFlow _frames;
  bool _selectionExplicit = false;
  bool _disposed = false;
  bool _suspended = false;
  bool _tickerVisible = true;
  bool get _capturePaused =>
      _suspended || !_tickerVisible || _control.cleaningUp;
  bool _handingOver = false;
  bool _userDetachedDuringHandover = false;
  BrowserTab? _boundTarget;
  String? _boundSession;
  int _streamGeneration = -1;
  int _editableQuery = 0;
  int _actionGeneration = 0;
  String? _actionError;
  int _captureGeneration = 0;
  int _frameStamp = 0;
  BrowserTab? _streaming;
  Future<void> _streamQueue = Future.value();
  Timer? _resize;

  /// The tab shown, its screencast started.
  BrowserTab? _shown;
  String? _detached;

  /// The last frame, and the page's size it shows (CSS pixels).
  Uint8List? _frame;
  Size? _pageSize;
  DateTime _lastFrame = DateTime(0);
  DateTime _lastShot = DateTime(0);
  bool _shooting = false;
  Timer? _watch;
  StreamSubscription<BrowserEvent>? _events;

  /// The view's size and pixels, for the frames' size.
  Size _viewSize = Size.zero;
  double _ratio = 1;

  final _focus = FocusNode(debugLabel: 'browser mirror');
  final _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _panel = BrowserPanelController()..addListener(_sync);
    _control.addListener(_controlChanged);
    _handingOver = _control.cleaningUp;
    _frames = BrowserFrameFlow(
      schedule: (callback) =>
          SchedulerBinding.instance.scheduleFrameCallback((_) => callback()),
      onFrame: (payload) {
        if (!mounted || _disposed || _capturePaused || _detached != null) return;
        try {
          final bytes = base64Decode(payload.data);
          setState(() {
            _frame = bytes;
            _pageSize = payload.pageSize;
          });
        } on FormatException {
          // An incomplete frame does not replace the last valid picture.
        }
      },
    );
    if (widget.initialTab case final tab?) {
      _selectionExplicit = true;
      _panel.select(tab);
    }
    _events = _bridge.events.listen(_received);
    _watch = Timer.periodic(const Duration(milliseconds: 300), (_) => _poll());
  }

  @override
  void didUpdateWidget(BrowserMirror oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTab != oldWidget.initialTab &&
        widget.initialTab != null && widget.initialTab != _panel.selected) {
      _pick(widget.initialTab!);
    }
    if (oldWidget.sessionId != widget.sessionId && _selectionExplicit) {
      _bindSelection();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _tickerVisible) {
      _tickerVisible = visible;
      if (!visible) {
        _releasePointer();
        _closeInput();
      }
      _restartStream();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final suspended = state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (_suspended == suspended) return;
    _suspended = suspended;
    if (suspended) {
      _releasePointer();
      _closeInput();
    }
    _restartStream();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _panel.removeListener(_sync);
    _panel.dispose();
    _control.removeListener(_controlChanged);
    unawaited(_events?.cancel());
    _watch?.cancel();
    _resize?.cancel();
    _releasePointer();
    _closeInput();
    _shown = null;
    _restartStream();
    _frames.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _controlChanged() {
    if (!mounted || _disposed) return;
    if (_control.cleaningUp && !_handingOver) {
      _handingOver = true;
      _actionGeneration++;
      _userDetachedDuringHandover = false;
      _editableQuery++;
      _releasePointer();
      _closeInput();
      _restartStream();
    } else if (!_control.cleaningUp && _handingOver) {
      _handingOver = false;
      // Only this explicit handover transition automatically restarts a
      // human view. A later user-cancelled debugger stays disconnected.
      if (_control.cleanupError == null && !_userDetachedDuringHandover &&
          (_shown == null || !_control.isDetached(_shown!))) {
        _detached = null;
        _restartStream();
      }
    }
    setState(() {});
  }

  void _bindSelection() {
    final tab = _panel.selected;
    if (tab == null || !_panel.connected ||
        (_boundTarget == tab && _boundSession == widget.sessionId)) {
      return;
    }
    _boundTarget = tab;
    _boundSession = widget.sessionId;
    _control.selectTarget(tab);
    if (widget.sessionId case final id?) _control.bindSession(id, tab);
    widget.onSelectionChanged?.call(tab);
  }

  void _sync() {
    if (!mounted || _disposed) return;
    final wanted = _panel.connected ? _panel.selected : null;
    if (wanted != _shown) {
      _actionGeneration++;
      // End input in its original tab before assigning another one.
      _releasePointer();
      _closeInput();
      _editableQuery++;
      _editable = false;
      _buttons = 0;
      _focus.unfocus();
      _shown = wanted;
      _detached = wanted != null && _control.isDetached(wanted)
          ? 'cancelled_by_user'
          : null;
      _frame = null;
      _pageSize = null;
      _lastFrame = DateTime(0);
      _lastShot = DateTime(0);
      _restartStream();
    }
    if (_selectionExplicit) _bindSelection();
    setState(() {});
  }

  /// Serialize stop/start so a late stop cannot kill the next stream.
  /// Each asynchronous transition is tied to the exact tab and generation.
  void _restartStream() {
    final generation = ++_captureGeneration;
    _streamGeneration = -1;
    _frames.reset();
    final tab = _shown;
    final width = (_viewSize.width * _ratio).round().clamp(320, 3840);
    final height = (_viewSize.height * _ratio).round().clamp(240, 3840);
    _streamQueue = _streamQueue.then((_) async {
      final previous = _streaming;
      _streaming = null;
      if (previous != null && !_control.isDetached(previous)) {
        try {
          await previous.browser.cdp(previous.tabId, 'Page.stopScreencast');
        } on Object {
          // The browser may have closed or stopped sharing this tab.
        }
      }
      if (_disposed || !mounted || _capturePaused || _detached != null ||
          tab == null || _control.isDetached(tab) ||
          generation != _captureGeneration || tab != _shown) {
        return;
      }
      _streaming = tab;
      _streamGeneration = generation;
      try {
        await tab.browser.cdp(tab.tabId, 'Page.startScreencast', {
          'format': 'jpeg',
          'quality': 70,
          'maxWidth': width,
          'maxHeight': height,
        });
      } on Object catch (error) {
        if (generation == _captureGeneration && mounted && !_disposed) {
          setState(() => _detached = '$error');
        }
      }
    });
  }

  /// A screenshot where the screencast has stopped (the tab behind
  /// another, its window out of sight) or sends nothing (the page still):
  /// a second apart at most.
  Future<void> _poll() async {
    final tab = _shown;
    if (tab == null || _shooting || _detached != null ||
        _capturePaused || _disposed) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastFrame) < const Duration(milliseconds: 600) ||
        now.difference(_lastShot) < const Duration(seconds: 1)) {
      return;
    }
    _shooting = true;
    _lastShot = now;
    final generation = _captureGeneration;
    final epoch = _frames.epoch;
    final stamp = ++_frameStamp;
    try {
      final view = await BrowserTools.viewport(tab.browser, tab.tabId);
      // As the screen has it, made small here: a screenshot's own scale
      // has the browser draw the page that small in its window meanwhile.
      if (generation != _captureGeneration || tab != _shown ||
          _disposed || _capturePaused) {
        return;
      }
      final shot = await tab.browser.cdp(tab.tabId, 'Page.captureScreenshot', {
        'format': 'jpeg',
        'quality': 70,
      });
      if (tab != _shown || !mounted || _disposed || _capturePaused ||
          generation != _captureGeneration) {
        return;
      }
      // A screencast's frame may have come meanwhile: the newer is kept.
      if (DateTime.now().difference(_lastFrame) <
          const Duration(milliseconds: 600)) {
        return;
      }
      _frames.push(
        data: shot['data'] as String,
        pageSize: view.rect.size,
        epoch: epoch,
        stamp: stamp,
      );
    } on Object {
      // Between pages, or gone.
    } finally {
      _shooting = false;
    }
  }

  void _received(BrowserEvent event) {
    final tab = _shown;
    switch (event.event) {
      case 'cdp':
        if (tab == null ||
            !identical(event.connection, tab.browser) ||
            event.tabId != tab.tabId ||
            event.message['method'] != 'Page.screencastFrame') {
          return;
        }
        if (_detached != null || _control.isDetached(tab)) {
          return;
        }
        final params = (event.message['params'] as Map).cast<String, Object?>();
        unawaited(
          tab.browser
              .cdp(tab.tabId, 'Page.screencastFrameAck', {
                'sessionId': params['sessionId'],
              })
              .then((_) {}, onError: (Object _) {}),
        );
        if (_capturePaused || _disposed || _streaming != tab ||
            _streamGeneration != _captureGeneration) {
          return;
        }
        final metadata = (params['metadata'] as Map).cast<String, Object?>();
        _lastFrame = DateTime.now();
        _frames.push(
          data: params['data'] as String,
          pageSize: Size(
            (metadata['deviceWidth'] as num).toDouble(),
            (metadata['deviceHeight'] as num).toDouble(),
          ),
          epoch: _frames.epoch,
          stamp: ++_frameStamp,
        );
      case 'detached':
        if (tab == null ||
            !identical(event.connection, tab.browser) ||
            event.tabId != tab.tabId) {
          return;
        }
        // chrome.debugger.detach does not send this event. It is an
        // external detach, including a user cancellation, even during cleanup.
        if (_handingOver) _userDetachedDuringHandover = true;
        _captureGeneration++;
        _streamGeneration = -1;
        _streaming = null;
        _editableQuery++;
        _editable = false;
        _buttons = 0;
        _lastPointer = null;
        _composing = false;
        _value = TextEditingValue.empty;
        _input?.close();
        _input = null;
        _frames.reset();
        setState(() => _detached = '${event.message['reason']}');
    }
  }

  void _retry() {
    final tab = _shown;
    if (tab == null || _control.cleaningUp || _control.cleanupError != null) return;
    _control.reconnectTab(tab);
    _control.selectTarget(tab);
    setState(() => _detached = null);
    _restartStream();
  }

  void _pick(BrowserTab tab) {
    _actionGeneration++;
    _control.reconnectTab(tab);
    _selectionExplicit = true;
    _panel.select(tab);
    _bindSelection();
    if (tab == _shown && _detached != null) _retry();
  }

  Future<void> _act(Future<void> Function() action, {bool select = false}) async {
    if (mounted) setState(() => _actionError = null);
    final selected = _panel.selected;
    final generation = ++_actionGeneration;
    try {
      await _control.ready;
      if (!mounted || _disposed || selected != _panel.selected ||
          generation != _actionGeneration) {
        return;
      }
      if (_control.cleanupError != null) {
        setState(() => _actionError = _control.cleanupError);
        return;
      }
      await action();
      if (!mounted || _disposed) return;
      if (select) {
        _selectionExplicit = true;
        _bindSelection();
      }
    } on Object catch (error) {
      if (mounted && !_disposed) setState(() => _actionError = '$error');
    }
  }

  // --- The input method: there while the page has the focus and what has
  // its focus takes text (asked after each click, each Tab).

  TextInputConnection? _input;
  TextEditingValue _value = TextEditingValue.empty;
  bool _composing = false;
  bool _editable = false;

  Future<void> _checkEditable() async {
    final tab = _shown;
    if (tab == null || _capturePaused || _disposed || _detached != null) return;
    final query = ++_editableQuery;
    try {
      final result = await tab.browser.cdp(tab.tabId, 'Runtime.evaluate', {
        'expression':
            '(() => { let e = document.activeElement;'
            ' while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;'
            ' if (e && e.tagName === "IFRAME") return true;'
            ' return !!e && (e.isContentEditable || e.tagName === "TEXTAREA" ||'
            ' (e.tagName === "INPUT" && !/^(button|checkbox|radio|submit|reset|file|image|range|color)\$/i.test(e.type))); })()',
        'returnByValue': true,
      });
      if (tab != _shown || !mounted || _disposed || query != _editableQuery) return;
      _editable = (result['result'] as Map?)?['value'] == true;
    } on Object {
      if (tab != _shown || !mounted || _disposed || query != _editableQuery) return;
      _editable = false;
    }
    _syncInput();
  }

  void _syncInput() {
    final wanted = !_disposed && !_capturePaused && _detached == null &&
        _focus.hasFocus && _editable && _shown != null;
    if (wanted && _input == null) {
      _value = TextEditingValue.empty;
      _input = TextInput.attach(
        this,
        TextInputConfiguration(
          // Windows takes no client without the view it types into.
          viewId: View.of(context).viewId,
          inputType: TextInputType.multiline,
          inputAction: TextInputAction.newline,
          autocorrect: false,
          enableSuggestions: false,
        ),
      )..show();
      _input!.setEditingState(_value);
      _placeInput();
    } else if (!wanted) {
      _closeInput();
    }
  }

  void _closeInput() {
    if (_composing) _ime('', commit: false);
    _composing = false;
    _input?.close();
    _input = null;
  }

  /// The input method's window, below the page's box (where the text is,
  /// the mirror does not know).
  void _placeInput() {
    final input = _input;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (input == null || box == null || !box.hasSize) return;
    input
      ..setEditableSizeAndTransform(box.size, box.getTransformTo(null))
      ..setComposingRect(Offset.zero & const Size(1, 1))
      ..setCaretRect(Offset.zero & const Size(1, 1));
  }

  void _ime(String text, {required bool commit, TextRange? selection}) {
    final tab = _shown;
    if (tab == null || _detached != null || _control.isDetached(tab)) {
      return;
    }
    final call = commit
        ? tab.browser.cdp(tab.tabId, 'Input.insertText', {'text': text})
        : tab.browser.cdp(tab.tabId, 'Input.imeSetComposition', {
            'text': text,
            'selectionStart': selection?.start ?? text.length,
            'selectionEnd': selection?.end ?? text.length,
          });
    unawaited(call.then((_) {}, onError: (Object _) {}));
  }

  @override
  TextEditingValue get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    if (_disposed || _capturePaused || _detached != null || _input == null) return;
    _value = value;
    final composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      _composing = true;
      final start = composing.start;
      final length = composing.end - start;
      _ime(
        composing.textInside(value.text),
        commit: false,
        selection: value.selection.isValid
            ? TextRange(
                start: (value.selection.start - start).clamp(0, length),
                end: (value.selection.end - start).clamp(0, length),
              )
            : null,
      );
      return;
    }
    final was = _composing;
    _composing = false;
    if (value.text.isNotEmpty) {
      _ime(value.text, commit: true);
    } else if (was) {
      _ime('', commit: false);
    }
    // Empty again for what comes next: the page keeps the text.
    _value = TextEditingValue.empty;
    _input?.setEditingState(_value);
  }

  @override
  void performAction(TextInputAction action) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _input = null;
    _composing = false;
  }

  // --- Keys.

  /// Whether [character] is text: not a control character, nor one of
  /// macOS's function keys' (U+F700…).
  static bool _types(String? character) {
    if (character == null || character.isEmpty) return false;
    final unit = character.codeUnitAt(0);
    return unit >= 0x20 && unit != 0x7F && (unit < 0xF700 || unit > 0xF8FF);
  }

  void _sendKey(
    String type,
    KeyEvent event, {
    String? text,
    List<String>? commands,
  }) {
    final tab = _shown;
    if (tab == null) return;
    if (_detached != null || _control.isDetached(tab)) {
      return;
    }
    final name = browserKeyName(event.physicalKey);
    final label = event.logicalKey.keyLabel;
    unawaited(
      tab.browser
          .cdp(tab.tabId, 'Input.dispatchKeyEvent', {
            'type': type,
            'modifiers': BrowserModifiers.keyboard,
            'windowsVirtualKeyCode': browserKeyCode(event.physicalKey),
            'key':
                name ??
                text ??
                (label.length == 1 ? label.toLowerCase() : label),
            'code': ?name,
            'text': ?text,
            'unmodifiedText': ?text,
            'commands': ?commands,
          })
          .then((_) {}, onError: (Object _) {}),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_shown == null) return KeyEventResult.ignored;
    if (_capturePaused || _detached != null) return KeyEventResult.handled;
    final keys = HardwareKeyboard.instance;
    final down = event is! KeyUpEvent;
    final mac = ideUsesMacKeys;
    // Ctrl elsewhere, on a key that types: Ctrl and an arrow, Backspace…
    // are the page's, and Ctrl with Alt is AltGr, which types.
    final shortcut = mac
        ? keys.isMetaPressed
        : keys.isControlPressed &&
              !keys.isAltPressed &&
              browserKeyName(event.physicalKey) == null;
    if (shortcut) {
      if (!down) return KeyEventResult.ignored;
      // The Edit menu's, as macOS's commands: what the page takes alone.
      final command = switch (event.logicalKey) {
        LogicalKeyboardKey.keyC => 'copy',
        LogicalKeyboardKey.keyX => 'cut',
        LogicalKeyboardKey.keyV => 'paste',
        LogicalKeyboardKey.keyA => 'selectAll',
        LogicalKeyboardKey.keyZ => keys.isShiftPressed ? 'redo' : 'undo',
        LogicalKeyboardKey.keyY when !mac => 'redo',
        _ => null,
      };
      // Any other is the app's (⌘W, ⌘P…; Ctrl+W, Ctrl+P elsewhere).
      if (command == null) return KeyEventResult.ignored;
      _sendKey('rawKeyDown', event, commands: [command]);
      _sendKey('keyUp', event);
      return KeyEventResult.handled;
    }
    // What the input method composes is its.
    if (_composing) return KeyEventResult.ignored;
    final control = browserKeyName(event.physicalKey) != null;
    final types =
        (!keys.isControlPressed || (!mac && keys.isAltPressed)) &&
        _types(event.character);
    // Text, where the page takes it, comes through the input method.
    if (_input != null && types && !control) return KeyEventResult.ignored;
    if (!down) {
      _sendKey('keyUp', event);
      return KeyEventResult.handled;
    }
    final enter = browserKeyName(event.physicalKey) == 'Enter';
    if (enter || (types && !control)) {
      _sendKey('keyDown', event, text: enter ? '\r' : event.character);
    } else {
      _sendKey('rawKeyDown', event);
    }
    if (event.physicalKey == PhysicalKeyboardKey.tab) {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 80), _checkEditable),
      );
    }
    return KeyEventResult.handled;
  }

  // --- The pointer, at the page's point (CSS pixels) under it.

  /// Where the frame is drawn in [size]: as big as fits, at the top.
  Rect _frameRect(Size size) =>
      browserFrameRect(size, _pageSize ?? Size.zero);

  Offset? _pagePoint(Offset local, {bool clamp = false}) {
    final page = _pageSize;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (page == null || box == null || !box.hasSize) return null;
    return browserPagePoint(local, box.size, page, clamp: clamp);
  }

  int _buttons = 0;
  int _clicks = 0;
  Duration? _lastDown;
  Offset? _lastDownAt;
  DateTime _lastMove = DateTime(0);
  Offset? _lastPointer;

  static String _button(int buttons) => switch (buttons) {
    kSecondaryButton => 'right',
    kMiddleMouseButton => 'middle',
    _ => 'left',
  };

  void _mouse(
    String type,
    Offset local, {
    String button = 'none',
    int clicks = 0,
    bool clamp = false,
  }) {
    final tab = _shown;
    final point = _pagePoint(local, clamp: clamp);
    if (tab == null || point == null || _detached != null ||
        _control.isDetached(tab)) {
      return;
    }
    _lastPointer = local;
    unawaited(
      tab.browser
          .cdp(tab.tabId, 'Input.dispatchMouseEvent', {
            'type': type,
            'x': point.dx,
            'y': point.dy,
            'button': button,
            'buttons': _buttons,
            'clickCount': clicks,
            'modifiers': BrowserModifiers.keyboard,
          })
          .then((_) {}, onError: (Object _) {}),
    );
  }

  void _releasePointer() {
    final at = _lastPointer;
    final held = _buttons;
    _buttons = 0;
    if (held != 0 && at != null) {
      _mouse('mouseReleased', at, button: _button(held), clamp: true);
    }
  }

  void _down(PointerDownEvent event) {
    if (_capturePaused || _detached != null ||
        _pagePoint(event.localPosition) == null) {
      return;
    }
    _focus.requestFocus();
    final again =
        _lastDownAt != null &&
        _lastDown != null &&
        (event.localPosition - _lastDownAt!).distance < 5 &&
        event.timeStamp - _lastDown! < const Duration(milliseconds: 500);
    _clicks = again ? _clicks % 3 + 1 : 1;
    _lastDown = event.timeStamp;
    _lastDownAt = event.localPosition;
    _buttons = event.buttons;
    _mouse(
      'mousePressed',
      event.localPosition,
      button: _button(event.buttons),
      clicks: _clicks,
    );
  }

  void _up(PointerUpEvent event) {
    if (_buttons == 0) return;
    final button = _button(_buttons);
    _buttons = 0;
    _mouse(
      'mouseReleased',
      event.localPosition,
      button: button,
      clicks: _clicks,
      clamp: true,
    );
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 80), _checkEditable),
    );
  }

  /// Moves, fewer while no button is down: enough for hovers.
  void _move(PointerEvent event) {
    if (_capturePaused || _detached != null) return;
    final now = DateTime.now();
    if (_buttons == 0 &&
        now.difference(_lastMove) < const Duration(milliseconds: 50)) {
      return;
    }
    _lastMove = now;
    _mouse(
      'mouseMoved',
      event.localPosition,
      button: _buttons == 0 ? 'none' : _button(_buttons),
      clamp: _buttons != 0,
    );
  }

  void _wheel(Offset local, Offset delta) {
    if (_capturePaused || _detached != null) return;
    final tab = _shown;
    final point = _pagePoint(local);
    final page = _pageSize;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (tab == null || point == null || page == null || box == null) return;
    // As far on the page as here: the page under the fingers follows them.
    final mapped = browserPageDelta(delta, box.size, page);
    if (mapped == null) return;
    unawaited(
      tab.browser
          .cdp(tab.tabId, 'Input.dispatchMouseEvent', {
            'type': 'mouseWheel',
            'x': point.dx,
            'y': point.dy,
            'deltaX': mapped.dx,
            'deltaY': mapped.dy,
            'modifiers': BrowserModifiers.keyboard,
          })
          .then((_) {}, onError: (Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final String? message;
    // Where to see why, and get the extension: none but a browser to share
    // a tab of.
    var settings = true;
    if (_bridge.otherApp) {
      message = l10n.browserOtherApp;
    } else if (_bridge.browsers.isEmpty) {
      message = l10n.browserNotConnected;
    } else if (_panel.selected == null) {
      settings = false;
      message = l10n.browserNoSharedTab;
    } else {
      message = null;
    }
    if (message != null && _panel.selected == null &&
        _bridge.browsers.isEmpty && !_control.manualControl) {
      final open = settings ? SettingsOpener.maybeOf(context) : null;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted),
              ),
              if (open != null) ...[
                const SizedBox(height: 12),
                IdeButton(
                  label: l10n.browserSettingsOpen,
                  icon: Codicons.settingsGear,
                  secondary: true,
                  onPressed: () => open(SettingsSection.browser),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final tab = _panel.selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BrowserPanelToolbar(
          title: _panel.title,
          url: _panel.url,
          connected: _panel.connected && _detached == null,
          browserName: tab?.browser.browser,
          bindingNotice: _bindingNotice(context),
          manualControl: _control.manualControl,
          error: _control.cleaningUp
              ? l10n.browserPanelPreparingControl
              : (_control.cleanupError ?? _actionError ?? _panel.error),
          tabs: () async {
            await _panel.refresh();
            return [
              for (final entry in _panel.tabs)
                IdeMenuAction(
                  '${entry.target.browser.browser ?? 'Chrome'} '
                  '#${_bridge.browsers.indexOf(entry.target.browser) + 1} '
                  '· ${entry.target.tabId}: '
                  '${entry.title.isEmpty ? entry.url : entry.title}',
                  checked: entry.target == tab,
                  onSelected: () => _pick(entry.target),
                ),
            ];
          },
          onNavigate: (url) => unawaited(_act(() => _panel.navigate(url))),
          onBack: () => unawaited(_act(_panel.back)),
          onForward: () => unawaited(_act(_panel.forward)),
          onReload: () => unawaited(_act(_panel.reload)),
          onNew: _canCreateTab
              ? () => unawaited(_act(_panel.newTab, select: true))
              : null,
          onClose: () => unawaited(_act(_panel.closeTab)),
          onShow: () => unawaited(_act(_panel.showInChrome)),
          onReconnectAgent: _canReconnectAgent ? _reconnectAgent : null,
          onTakeOver: _control.takeOver,
          onResume: _control.resume,
        ),
        Expanded(
          child: _shown == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _panel.error ?? message ?? l10n.browserNoSharedTab,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                        if (settings && SettingsOpener.maybeOf(context) != null) ...[
                          const SizedBox(height: 12),
                          IdeButton(
                            label: l10n.browserSettingsOpen,
                            icon: Codicons.settingsGear,
                            secondary: true,
                            onPressed: () => SettingsOpener.maybeOf(context)
                                ?.call(SettingsSection.browser),
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              : _page(context),
        ),
      ],
    );
  }

  String _connectionLabel(BuildContext context, BrowserConnection browser) {
    final name = browser.browser ?? 'Chrome';
    if (!browser.connected) {
      return context.l10n.browserPanelDisconnectedConnection(name);
    }
    final index = _bridge.browsers.indexOf(browser);
    return index < 0 ? name : '$name #${index + 1}';
  }

  String? _bindingNotice(BuildContext context) {
    final sessionId = widget.sessionId;
    final selected = _panel.selected;
    if (sessionId == null || selected == null) return null;
    final bound = _control.boundBrowserForSession(sessionId);
    if (bound == null || identical(bound, selected.browser)) return null;
    return context.l10n.browserPanelBindingNotice(
      _connectionLabel(context, selected.browser),
      _connectionLabel(context, bound),
    );
  }

  void _reconnectAgent() {
    final sessionId = widget.sessionId;
    final selected = _panel.selected;
    if (sessionId == null || selected == null || !_panel.connected) return;
    try {
      _control.rebindSession(sessionId, selected);
      setState(() => _actionError = null);
    } on Object catch (error) {
      setState(() => _actionError = '$error');
    }
  }

  bool get _canReconnectAgent {
    final sessionId = widget.sessionId;
    final selected = _panel.selected;
    return sessionId != null && selected != null && _panel.connected &&
        _control.canRebindSession(sessionId, selected);
  }

  bool get _canCreateTab {
    final browser = _panel.selected?.browser;
    return browser == null
        ? _bridge.browsers.length == 1
        : _bridge.browsers.any((other) => identical(other, browser));
  }

  Widget _page(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final ratioChanged = ratio != _ratio;
    _ratio = ratio;
    final frame = _frame;
    final detached = _detached;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _viewSize || ratioChanged) {
          _viewSize = size;
          // Debounced while the sash moves, using the latest pane size.
          _resize?.cancel();
          _resize = Timer(const Duration(milliseconds: 150), () {
            if (mounted && !_disposed) {
              _restartStream();
              _placeInput();
            }
          });
        }
        return Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          onFocusChange: (focused) {
            if (!focused) _releasePointer();
            _syncInput();
          },
          child: Listener(
            key: _key,
            onPointerDown: _down,
            onPointerUp: _up,
            onPointerCancel: (_) => _releasePointer(),
            onPointerMove: _move,
            onPointerHover: _move,
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _wheel(event.localPosition, event.scrollDelta);
              }
            },
            onPointerPanZoomUpdate: (event) =>
                _wheel(event.localPosition, -event.localPanDelta),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (frame != null)
                  Positioned.fromRect(
                    rect: _frameRect(size),
                    child: Image.memory(
                      frame,
                      gaplessPlayback: true,
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                if (detached != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            context.l10n.browserDetached,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.textMuted),
                          ),
                          const SizedBox(height: 8),
                          IdeActionButton(
                            icon: Codicons.refresh,
                            tooltip: context.l10n.browserReconnect,
                            onPressed: _retry,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
