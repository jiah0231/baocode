// Test-only native-protocol adapter. CDP replies/events come from real Chrome;
// this is deliberately NOT coverage of chrome.debugger or host installation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:baocode/browser/browser_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'chrome_sandbox_guard.dart';

class RealChromeFixture {
  RealChromeFixture(this.root, this.page) {
    _client.connectionTimeout = const Duration(seconds: 5);
  }

  final Directory root;
  final Uri page;
  Process? _process;
  final _client = HttpClient();
  int _outputCharacters = 0;
  late final _sandbox = ChromeSandboxGuard(onViolation: _stopForSandboxFailure);
  final _outputDone = <Future<void>>[];
  final _outputSubscriptions = <StreamSubscription<String>>[];
  void Function()? _testStopOwnedProcess;

  Uri? _endpoint;
  Socket? _native;
  int _nativeGeneration = 0;
  final _inflight = <Future<void>>{};
  _CdpSocket? _cdp;
  Future<_CdpSocket>? _attaching;
  String? _target;
  bool _closed = false;
  int attaches = 0;
  int detaches = 0;
  bool holdBindings = false;
  bool holdNextEvaluation = false;
  bool suppressScreencastFrames = false;
  int forwardedScreencastFrames = 0;
  int suppressedScreencastFrames = 0;
  int screenshotReplies = 0;
  Map<String, Object?>? heldEvaluation;
  Socket? _heldEvaluationSocket;
  int? _heldEvaluationGeneration;
  int discardedStaleReplies = 0;
  final heldBindings = <Map<String, Object?>>[];
  final events = <Map<String, Object?>>[];
  final commands = <String>[];
  // Bounded input/capture evidence from this fixture only, never page scripts.
  final commandDetails = <Map<String, Object?>>[];
  bool _captureNavigation = false;
  bool _navigationOnlyNetwork = false;
  bool get captureNavigation => _captureNavigation;
  set captureNavigation(bool value) {
    _captureNavigation = value;
    if (value) _navigationOnlyNetwork = true;
  }
  final navigationEvents = <Map<String, Object?>>[];
  final acknowledgements = <String>[];
  final errors = <String>[];

  void _stopForSandboxFailure() {
    // Latch first, then stop transport synchronously. A Chrome child may fall
    // back after a sandbox launch failure; subsequent successful CDP/DOM work
    // must never turn this run into a pass. Only our owned process is stopped.
    errors.add('Chrome sandbox/output monitoring failed; fixture stopped.');
    for (final stop in <void Function()>[
      disconnectNative,
      () { _client.close(force: true); },
      () { _cdp?.abort(); },
      () { _process?.kill(); },
      () { _testStopOwnedProcess?.call(); },
    ]) {
      try {
        stop();
      } on Object {
        // A transport failure must not prevent stopping the owned process.
        errors.add('Chrome fixture stop action failed after sandbox violation.');
      }
    }
  }

  void _monitorOutput(String name, Stream<List<int>> output) {
    final done = Completer<void>();
    _outputDone.add(done.future);
    _outputSubscriptions.add(output.transform(utf8.decoder).listen((text) {
      _sandbox.addOutput(name, text);
      // Keep no raw output, executable paths or profile names. Only the
      // guard's bounded marker tails and a capped diagnostic count survive.
      _outputCharacters = math.min(0x7fffffff, _outputCharacters + text.length);
    }, onError: (Object _) {
      _sandbox.failMonitoring();
    }, onDone: () {
      // Unexpected EOF means later sandbox diagnostics are no longer visible.
      // During close we deliberately stop Chrome, so EOF is expected then.
      if (!_closed) {
        _sandbox.failMonitoring();
      }
      done.complete();
    }));
  }

  /// Synthetic test seam: connects only supplied in-memory output streams.
  /// It cannot launch a process or bypass the real fixture's security checks.
  @visibleForTesting
  void monitorOutputForTesting(Stream<List<int>> stdout,
      Stream<List<int>> stderr, {required void Function() stopOwnedProcess}) {
    if (_process != null || _outputDone.isNotEmpty || _closed) {
      throw StateError('Output monitoring has already started.');
    }
    _testStopOwnedProcess = stopOwnedProcess;
    _monitorOutput('stdout', stdout);
    _monitorOutput('stderr', stderr);
  }

  @visibleForTesting
  Future<T> guardedOperationForTesting<T>(Future<T> Function() operation) =>
      _sandbox.run(operation);

  @visibleForTesting
  void acceptCdpEventForTesting(Map<String, Object?> event) => _event(event);

  Future<void> start(String executable, String version, {
    double browserZoom = 1,
    double? deviceScaleFactor,
    bool initiallyBlank = false,
  }) async {
    _sandbox.check();
    if (_closed || _outputDone.isNotEmpty) {
      throw StateError('Fixture has already started or closed.');
    }
    if (!File(executable).existsSync()) {
      throw StateError('Official Chrome for Testing executable not found.');
    }
    if (!browserZoom.isFinite || browserZoom < 0.5 || browserZoom > 3 ||
        (deviceScaleFactor != null && (!deviceScaleFactor.isFinite ||
            deviceScaleFactor < 0.5 || deviceScaleFactor > 4))) {
      throw ArgumentError('Fixture zoom/device scale is outside its test range.');
    }
    final profile = Directory(p.join(root.path, 'disposable-chrome-profile'));
    if (profile.existsSync()) {
      throw StateError('Refusing to reuse an existing Chrome profile.');
    }
    profile.createSync();
    if (browserZoom != 1) {
      // Chromium ChromeZoomLevelPrefs uses partition key "x" for the default
      // partition, and Blink converts levels with factor = pow(1.2, level).
      // This changes real browser zoom, not CSS zoom or pinch emulation. The
      // widget smoke independently verifies cssVisualViewport.zoom at runtime.
      final defaults = Directory(p.join(profile.path, 'Default'))..createSync();
      File(p.join(defaults.path, 'Preferences')).writeAsStringSync(jsonEncode({
        'partition': {
          'default_zoom_level': {'x': math.log(browserZoom) / math.log(1.2)},
        },
      }));
    }
    final initialPage = initiallyBlank ? Uri.parse('about:blank') : page;
    _process = await Process.start(executable, [
      '--user-data-dir=${profile.path}',
      '--remote-debugging-address=127.0.0.1',
      '--remote-debugging-port=0',
      '--headless=new',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-sync',
      '--disable-extensions',
      '--window-size=900,700',
      if (deviceScaleFactor != null)
        '--force-device-scale-factor=$deviceScaleFactor',
      initialPage.toString(),
    ]);
    // Drain both pipes so a verbose browser cannot deadlock the test.
    _monitorOutput('stdout', _process!.stdout);
    _monitorOutput('stderr', _process!.stderr);
    final portFile = File(p.join(profile.path, 'DevToolsActivePort'));
    var port = 0;
    try {
      await chromeUntil(() {
        _sandbox.check();
        if (!portFile.existsSync()) {
          return false;
        }
        final List<String> lines;
        try {
          lines = portFile.readAsLinesSync();
        } on FileSystemException catch (error) {
          if (Platform.isWindows && error.osError?.errorCode == 32) {
            return false;
          }
          rethrow;
        }
        if (lines.length < 2) {
          return false;
        }
        port = int.tryParse(lines.first) ?? 0;
        return port > 0 && port <= 65535;
      }, reason: 'Chrome did not expose its disposable DevTools endpoint.');
    } on Object catch (error) {
      _sandbox.check();
      throw StateError('$error\nChrome output characters observed: '
          '$_outputCharacters (raw output omitted).');
    }
    _endpoint = Uri.parse('http://127.0.0.1:$port');
    final browser = (await _json('/json/version')) as Map;
    if (browser['Browser'] != 'Chrome/$version' &&
        browser['Browser'] != 'HeadlessChrome/$version') {
      throw StateError('Chrome version differs from pinned CfT version: '
          '${browser['Browser']} (expected $version).');
    }
    // Target metadata identifies a startup tab, not a committed document.
    await chromeUntil(() async {
      final targets = (await _json('/json/list')) as List;
      final ours = targets.cast<Map>().where(
        (target) => target['type'] == 'page' && target['url'] == '$initialPage',
      );
      if (ours.isEmpty) {
        return false;
      }
      _target = ours.single['id'] as String;
      return true;
    }, reason: 'The requested local fixture target did not appear.');
    if (initiallyBlank) {
      // Do not navigate Chrome's startup-owned tab. The DevTools HTTP handler
      // supports PUT /json/new and creates a separate foreground tab. Keep the
      // takeover fixture's default startup-target behavior unchanged.
      final target = (await _json('/json/new?about:blank', createTarget: true)) as Map;
      final id = target['id'];
      if (target['type'] != 'page' || target['url'] != 'about:blank' ||
          id is! String || id.isEmpty || id == _target) {
        throw StateError('Chrome did not create a distinct blank fixture target.');
      }
      _target = id;
    }
    await connectNative();
    _sandbox.check();
  }

  Future<void> connectNative() async {
    _sandbox.check();
    final parts = File(BrowserBridge.portPath).readAsStringSync().split(' ');
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4, int.parse(parts[0]),
    ).timeout(const Duration(seconds: 5));
    if (_closed || _sandbox.failed) {
      socket.destroy();
      _sandbox.check();
      throw StateError('Fixture closed during native connection.');
    }
    final generation = ++_nativeGeneration;
    final buffer = BytesBuilder(copy: false);
    _native = socket;
    socket.listen((data) => _read(socket, generation, buffer, data),
        onError: (Object error) {
      if (!_closed) {
        errors.add('native socket: $error');
      }
    });
    _send({
      'type': 'hello',
      'origin': 'chrome-extension://${BrowserBridge.extensionIds.first}/',
      'token': parts[1],
    });
    _send({
      'type': 'hello',
      'browser': 'Chrome for Testing (CDP fixture)',
      'version': 'test-only',
      'protocol': BrowserBridge.protocol,
      'capabilities': ['cdp.session'],
    });
  }

  void disconnectNative() {
    _native?.destroy();
    _native = null;
    _nativeGeneration++;
  }

  Future<Object?> _json(String path, {bool createTarget = false}) =>
      _sandbox.run(() async {
    if (createTarget && path != '/json/new?about:blank') {
      throw StateError('Only a new blank fixture target may be created.');
    }
    final request = await _client.openUrl(
      createTarget ? 'PUT' : 'GET', _endpoint!.resolve(path),
    );
    _sandbox.check();
    final response = await request.close();
    _sandbox.check();
    if (response.statusCode != 200) {
      throw StateError('Chrome endpoint $path: ${response.statusCode}');
    }
    final body = await utf8.decodeStream(response);
    _sandbox.check();
    return jsonDecode(body);
  });

  Future<_CdpSocket> _attached() {
    _sandbox.check();
    if (_cdp case final current?) {
      return Future.value(current);
    }
    return _attaching ??= () async {
      try {
        final targets = (await _json('/json/list')) as List;
        final target = targets.cast<Map>().singleWhere(
          (target) => target['id'] == _target,
        );
        final url = Uri.parse(target['webSocketDebuggerUrl'] as String);
        if (url.host != '127.0.0.1' || url.port != _endpoint!.port) {
          throw StateError('Refusing a non-fixture CDP endpoint.');
        }
        _sandbox.check();
        final connected = _CdpSocket(await WebSocket.connect('$url')
            .timeout(const Duration(seconds: 5)), _event);
        if (_closed || _sandbox.failed) {
          await connected.close();
          _sandbox.check();
          throw StateError('Fixture closed during CDP attachment.');
        }
        _cdp = connected;
        attaches++;
        return connected;
      } finally {
        _attaching = null;
      }
    }();
  }

  void _event(Map<String, Object?> raw) {
    if (_closed || _sandbox.failed) {
      return;
    }
    if (captureNavigation) {
      _recordNavigation(raw);
    }
    // Network is temporarily enabled only for local startup diagnostics.
    // Keep filtering after disable too, in case a buffered event arrives late.
    // The takeover fixture never enables this navigation-only filtering mode.
    if (_navigationOnlyNetwork &&
        (raw['method'] as String).startsWith('Network.')) {
      return;
    }
    final event = <String, Object?>{
      'type': 'event', 'event': 'cdp', 'tabId': 1, ...raw,
    };
    events.add(event);
    if (raw['method'] == 'Page.screencastFrame') {
      if (suppressScreencastFrames) {
        suppressedScreencastFrames++;
        // ACK the actual frame even when the mirror cannot see it, otherwise
        // Chrome stalls and resuming forwarding would not exercise a stream.
        final cdp = _cdp;
        if (cdp != null && !_closed) {
          late Future<void> pending;
          pending = _sandbox.run(() => cdp.call('Page.screencastFrameAck', {
            'sessionId': (raw['params'] as Map)['sessionId'],
          })).then<void>((_) {}, onError: (Object error) {
            if (!_closed) errors.add('suppressed frame ACK: $error');
          }).whenComplete(() { _inflight.remove(pending); });
          _inflight.add(pending);
          unawaited(pending);
        }
        return;
      }
      forwardedScreencastFrames++;
    }
    if (holdBindings && raw['method'] == 'Runtime.bindingCalled') {
      heldBindings.add(event);
    } else {
      _send(event);
    }
  }

  void _recordNavigation(Map<String, Object?> raw) {
    final method = raw['method'];
    if (!const {
      'Page.frameStartedLoading', 'Page.frameStoppedLoading',
      'Page.frameStartedNavigating', 'Page.frameRequestedNavigation',
      'Page.frameNavigated', 'Page.lifecycleEvent',
      'Network.requestWillBeSent', 'Network.loadingFailed',
    }.contains(method)) {
      return;
    }
    final params = (raw['params'] as Map? ?? {}).cast<String, Object?>();
    final details = <String, Object?>{'method': method, 'targetId': _target};
    for (final key in const [
      'frameId', 'loaderId', 'requestId', 'type', 'name', 'timestamp',
      'reason', 'disposition', 'navigationType', 'errorText', 'canceled',
      'blockedReason',
    ]) {
      if (params.containsKey(key)) details[key] = params[key];
    }
    final frame = params['frame'] as Map?;
    if (frame != null) {
      details['frameId'] = frame['id'];
      details['loaderId'] = frame['loaderId'];
    }
    final request = params['request'] as Map?;
    final url = params['url'] ?? frame?['url'] ?? request?['url'];
    if (url != null) {
      details['document'] = url == '$page' ? 'fixture'
          : url == 'about:blank' ? 'blank' : 'other';
    }
    final initiator = params['initiator'] as Map?;
    if (initiator != null) details['initiatorType'] = initiator['type'];
    if (navigationEvents.length == 32) navigationEvents.removeAt(0);
    navigationEvents.add(details);
  }

  /// Replays only exact events captured from Chrome, never invented payloads.
  void releaseEvaluation() {
    final response = heldEvaluation;
    final socket = _heldEvaluationSocket;
    final generation = _heldEvaluationGeneration;
    heldEvaluation = null;
    _heldEvaluationSocket = null;
    _heldEvaluationGeneration = null;
    if (response != null && socket != null && generation != null) {
      _sendReply(socket, generation, response);
    }
  }

  void releaseBindings() {
    holdBindings = false;
    for (final event in heldBindings) {
      _send(event);
    }
    heldBindings.clear();
  }

  void _send(Map<String, Object?> value) {
    final socket = _native;
    if (socket == null || _closed || _sandbox.failed) {
      return;
    }
    _sendReply(socket, _nativeGeneration, value);
  }

  void _sendReply(Socket socket, int generation, Map<String, Object?> value) {
    if (_closed || _sandbox.failed || generation != _nativeGeneration ||
        !identical(socket, _native)) {
      discardedStaleReplies++;
      return;
    }
    final body = utf8.encode(jsonEncode(value));
    final header = ByteData(4)..setUint32(0, body.length, Endian.little);
    try {
      socket..add(header.buffer.asUint8List())..add(body);
    } on Object catch (error) {
      errors.add('native reply write: $error');
    }
  }

  void _read(Socket socket, int generation, BytesBuilder buffer, Uint8List data) {
    if (_closed || _sandbox.failed || generation != _nativeGeneration ||
        !identical(socket, _native)) {
      return;
    }
    buffer.add(data);
    final bytes = buffer.takeBytes();
    var offset = 0;
    while (bytes.length - offset >= 4) {
      final size = ByteData.sublistView(bytes, offset, offset + 4)
          .getUint32(0, Endian.little);
      if (bytes.length - offset - 4 < size) {
        break;
      }
      final request = (jsonDecode(utf8.decode(
        bytes.sublist(offset + 4, offset + 4 + size),
      )) as Map).cast<String, Object?>();
      offset += 4 + size;
      late Future<void> pending;
      pending = _handle(socket, generation, request).whenComplete(() {
        _inflight.remove(pending);
      });
      _inflight.add(pending);
      unawaited(pending);
    }
    if (offset < bytes.length) {
      buffer.add(bytes.sublist(offset));
    }
  }

  Future<void> _handle(Socket socket, int generation,
      Map<String, Object?> request) async {
    if (request['id'] == null) {
      return;
    }
    final method = request['method'];
    final params = (request['params'] as Map? ?? {}).cast<String, Object?>();
    try {
      _sandbox.check();
      Object? result;
      switch (method) {
        case 'cdp':
          if (params['tabId'] != 1) {
            throw StateError('Not the fixture tab.');
          }
          final name = params['method'] as String;
          final args = (params['params'] as Map? ?? {}).cast<String, Object?>();
          if (name == 'Page.navigate' && args['url'] != '$page') {
            throw StateError('Only the local fixture URL is permitted.');
          }
          commands.add(name);
          if (name == 'Input.dispatchMouseEvent' ||
              name == 'Page.startScreencast' ||
              name == 'Page.captureScreenshot') {
            if (commandDetails.length == 128) commandDetails.removeAt(0);
            commandDetails.add({'method': name, 'params': Map.of(args)});
          }
          final cdp = await _sandbox.run(_attached);
          result = await _sandbox.run(() => cdp.call(name, args,
              sessionId: params['sessionId'] as String?));
          _sandbox.check();
          acknowledgements.add(name);
          if (name == 'Page.captureScreenshot') screenshotReplies++;
          if (name == 'Runtime.evaluate' && holdNextEvaluation) {
            holdNextEvaluation = false;
            heldEvaluation = {'id': request['id'], 'result': result};
            _heldEvaluationSocket = socket;
            _heldEvaluationGeneration = generation;
            return;
          }
        case 'tabs.list':
          final targets = (await _json('/json/list')) as List;
          final target = targets.cast<Map>().singleWhere(
            (target) => target['id'] == _target,
          );
          result = [{
            'tabId': 1, 'windowId': 1, 'active': true, 'loading': false,
            'title': target['title'], 'url': target['url'],
          }];
        case 'detach':
          final cdp = _cdp;
          _cdp = null;
          await cdp?.close();
          detaches++;
          // An explicit detach closes the real session. Do not invent an
          // extension onDetach event: that API is outside this fixture.
        case 'watch':
          // Only the extension badge is stubbed; recorder bindings are real.
          break;
        default:
          throw UnsupportedError('Unsupported fixture method $method');
      }
      _sandbox.check();
      _sendReply(socket, generation, {'id': request['id'], 'result': result});
    } on Object catch (error) {
      errors.add('$method ${params['method'] ?? ''}: $error');
      _sendReply(socket, generation, {'id': request['id'], 'error': '$error'});
    }
  }

  /// Settle commands dispatched before a test's explicit transport barrier.
  Future<void> drain() async {
    _sandbox.check();
    await () async {
      while (_inflight.isNotEmpty) {
        await Future.wait(_inflight.toList());
      }
    }().timeout(const Duration(seconds: 6));
    _sandbox.check();
  }

  Future<void> close() async {
    _closed = true;
    disconnectNative();
    _client.close(force: true);
    try {
      try {
        await _cdp?.close();
      } finally {
        // No new handlers can enter after closure. Drain the dispatched work
        // before callers inspect errors, including requests still attaching.
        try {
          await Future.wait(_inflight.toList()).timeout(const Duration(seconds: 6));
        } on Object catch (error) {
          errors.add('Closing fixture with unfinished native handlers: $error');
          rethrow;
        }
      }
    } finally {
      try {
        final process = _process;
        if (process != null) {
          process.kill();
          try {
            await process.exitCode.timeout(const Duration(seconds: 10));
          } on TimeoutException {
            process.kill(ProcessSignal.sigkill);
            await process.exitCode.timeout(const Duration(seconds: 5));
          }
        }
      } finally {
        // Process exit is not pipe EOF. A denial delivered during shutdown
        // still invalidates the test. Missing/broken output is fail closed.
        try {
          await Future.wait(_outputDone).timeout(const Duration(seconds: 5));
        } on Object {
          _sandbox.failMonitoring();
        } finally {
          try {
            await Future.wait(_outputSubscriptions.map((s) => s.cancel()))
                .timeout(const Duration(seconds: 5));
          } on Object {
            _sandbox.failMonitoring();
          }
          _sandbox.check();
        }
      }
    }
  }
}

class _CdpSocket {
  _CdpSocket(this.socket, void Function(Map<String, Object?>) event) {
    socket.listen((Object? data) {
      final message = (jsonDecode(data as String) as Map).cast<String, Object?>();
      if (message['id'] case final int id) {
        final pending = _pending.remove(id);
        if (pending == null) {
          return;
        }
        if (message['error'] case final Object error) {
          pending.completeError(StateError('CDP: $error'));
        } else {
          pending.complete((message['result'] as Map? ?? {}).cast<String, Object?>());
        }
      } else if (message['method'] != null) {
        event(message);
      }
    }, onDone: _ended, onError: (Object _) => _ended());
  }

  final WebSocket socket;
  final _pending = <int, Completer<Map<String, Object?>>>{};
  final _done = Completer<void>();
  int _nextId = 0;
  bool _closed = false;

  Future<Map<String, Object?>> call(String method,
      Map<String, Object?> params, {String? sessionId}) {
    if (_closed) {
      return Future.error(StateError('Real Chrome CDP session closed.'));
    }
    final id = ++_nextId;
    final result = Completer<Map<String, Object?>>();
    _pending[id] = result;
    socket.add(jsonEncode({
      'id': id, 'method': method, 'params': params,
      'sessionId': ?sessionId,
    }));
    return result.future.timeout(const Duration(seconds: 15)).whenComplete(
      () { _pending.remove(id); },
    );
  }

  void _ended() {
    _closed = true;
    for (final result in _pending.values) {
      result.completeError(StateError('Real Chrome CDP session closed.'));
    }
    _pending.clear();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  void abort() {
    _ended();
    // Close transport only, never send a Chrome command after a violation.
    unawaited(socket.close().timeout(const Duration(seconds: 5))
        .then<void>((_) {}, onError: (Object _) {}));
  }

  Future<void> close() async {
    await socket.close().timeout(const Duration(seconds: 5));
    await _done.future.timeout(const Duration(seconds: 5));
  }
}

Future<void> chromeUntil(FutureOr<bool> Function() condition, {
  String reason = 'Real Chrome smoke condition timed out.',
  Duration timeout = const Duration(seconds: 15),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (await condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException(reason, timeout);
}
