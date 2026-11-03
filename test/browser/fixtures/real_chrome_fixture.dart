// Test-only native-protocol adapter. CDP replies/events come from real Chrome;
// this is deliberately NOT coverage of chrome.debugger or host installation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/browser/browser_bridge.dart';
import 'package:path/path.dart' as p;

class RealChromeFixture {
  RealChromeFixture(this.root, this.page) {
    _client.connectionTimeout = const Duration(seconds: 5);
  }

  final Directory root;
  final Uri page;
  Process? _process;
  final _client = HttpClient();
  final _log = StringBuffer();
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
  Map<String, Object?>? heldEvaluation;
  Socket? _heldEvaluationSocket;
  int? _heldEvaluationGeneration;
  int discardedStaleReplies = 0;
  final heldBindings = <Map<String, Object?>>[];
  final events = <Map<String, Object?>>[];
  final commands = <String>[];
  final acknowledgements = <String>[];
  final errors = <String>[];

  Future<void> start(String executable, String version) async {
    if (!File(executable).existsSync()) {
      throw StateError('Official Chrome for Testing executable not found.');
    }
    final profile = Directory(p.join(root.path, 'disposable-chrome-profile'))
      ..createSync();
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
      page.toString(),
    ]);
    // Drain both pipes so a verbose browser cannot deadlock the test.
    _process!.stdout.transform(utf8.decoder).listen(_log.write);
    _process!.stderr.transform(utf8.decoder).listen(_log.write);
    final portFile = File(p.join(profile.path, 'DevToolsActivePort'));
    var port = 0;
    try {
      await chromeUntil(() {
        if (!portFile.existsSync()) {
          return false;
        }
        final lines = portFile.readAsLinesSync();
        if (lines.length < 2) {
          return false;
        }
        port = int.tryParse(lines.first) ?? 0;
        return port > 0 && port <= 65535;
      }, reason: 'Chrome did not expose its disposable DevTools endpoint.');
    } on Object catch (error) {
      throw StateError('$error\nChrome output: $_log');
    }
    _endpoint = Uri.parse('http://127.0.0.1:$port');
    final browser = (await _json('/json/version')) as Map;
    if (browser['Browser'] != 'Chrome/$version' &&
        browser['Browser'] != 'HeadlessChrome/$version') {
      throw StateError('Chrome version differs from pinned CfT version: '
          '${browser['Browser']} (expected $version).');
    }
    await chromeUntil(() async {
      final targets = (await _json('/json/list')) as List;
      final ours = targets.cast<Map>().where(
        (target) => target['type'] == 'page' && target['url'] == '$page',
      );
      if (ours.isEmpty) {
        return false;
      }
      _target = ours.single['id'] as String;
      return true;
    }, reason: 'Local fixture page did not load.');
    await connectNative();
  }

  Future<void> connectNative() async {
    final parts = File(BrowserBridge.portPath).readAsStringSync().split(' ');
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4, int.parse(parts[0]),
    );
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

  Future<Object?> _json(String path) async {
    final request = await _client.getUrl(_endpoint!.resolve(path));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError('Chrome endpoint $path: ${response.statusCode}');
    }
    return jsonDecode(await utf8.decodeStream(response));
  }

  Future<_CdpSocket> _attached() {
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
        final connected = _CdpSocket(await WebSocket.connect('$url')
            .timeout(const Duration(seconds: 5)), _event);
        if (_closed) {
          await connected.close();
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
    final event = <String, Object?>{
      'type': 'event', 'event': 'cdp', 'tabId': 1, ...raw,
    };
    events.add(event);
    if (holdBindings && raw['method'] == 'Runtime.bindingCalled') {
      heldBindings.add(event);
    } else {
      _send(event);
    }
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
    if (socket == null || _closed) {
      return;
    }
    _sendReply(socket, _nativeGeneration, value);
  }

  void _sendReply(Socket socket, int generation, Map<String, Object?> value) {
    if (_closed || generation != _nativeGeneration || !identical(socket, _native)) {
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
    if (_closed || generation != _nativeGeneration || !identical(socket, _native)) {
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
          final cdp = await _attached();
          result = await cdp.call(name, args,
              sessionId: params['sessionId'] as String?);
          acknowledgements.add(name);
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
      _sendReply(socket, generation, {'id': request['id'], 'result': result});
    } on Object catch (error) {
      errors.add('$method ${params['method'] ?? ''}: $error');
      _sendReply(socket, generation, {'id': request['id'], 'error': '$error'});
    }
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

  Future<Map<String, Object?>> call(String method,
      Map<String, Object?> params, {String? sessionId}) {
    final id = ++_nextId;
    final result = Completer<Map<String, Object?>>();
    _pending[id] = result;
    socket.add(jsonEncode({
      'id': id, 'method': method, 'params': params,
      if (sessionId != null) 'sessionId': sessionId,
    }));
    return result.future.timeout(const Duration(seconds: 15)).whenComplete(
      () { _pending.remove(id); },
    );
  }

  void _ended() {
    for (final result in _pending.values) {
      result.completeError(StateError('Real Chrome CDP session closed.'));
    }
    _pending.clear();
    if (!_done.isCompleted) {
      _done.complete();
    }
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
