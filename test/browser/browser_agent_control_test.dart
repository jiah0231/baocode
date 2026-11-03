import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/browser/browser_agent_control.dart';
import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/browser/browser_records.dart';
import 'package:baocode/browser/browser_tools.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final bridge = BrowserBridge.instance;
  final control = BrowserAgentControl.instance;
  late Directory temp;
  late DataDirectory oldData;
  late bool oldLoopback;
  final peers = <_NativePeer>[];

  Future<_NativePeer> connect(String name) async {
    final [port, token] = File(BrowserBridge.portPath)
        .readAsStringSync().split(' ');
    final peer = _NativePeer(await Socket.connect(
      InternetAddress.loopbackIPv4, int.parse(port),
    ));
    peers.add(peer);
    peer.send({
      'type': 'hello',
      'origin': 'chrome-extension://${BrowserBridge.extensionIds.first}/',
      'token': token,
    });
    peer.send({'type': 'hello', 'browser': name, 'protocol': 1});
    await _until(() => bridge.browsers.any((b) => b.browser == name));
    peer.browser = bridge.browsers.singleWhere((b) => b.browser == name);
    return peer;
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('bao-control-');
    oldData = DataDirectory.current;
    DataDirectory.current = DataDirectory(p.join(temp.path, 'data'));
    oldLoopback = BrowserBridge.loopback;
    BrowserBridge.loopback = true;
    BrowserBridge.socketFolder = temp.path;
    BrowserBridge.home = p.join(temp.path, 'home');
    BrowserHistory.folderOverride = p.join(temp.path, 'history');
    control.resetForTesting();
    expect(control.manualControl, isTrue);
    control.resume(); // Fresh explicit permission for this isolated test run.
    expect(control.manualControl, isFalse);
    bridge.enabled = true;
    await bridge.start();
  });

  tearDown(() async {
    BrowserTools.unregister();
    BrowserWatching.current.value?.cancel();
    await control.ready;
    for (final peer in peers) {
      peer.socket.destroy();
    }
    peers.clear();
    await bridge.stop();
    control.resetForTesting();
    BrowserBridge.loopback = oldLoopback;
    BrowserBridge.socketFolder = null;
    BrowserBridge.home = null;
    BrowserHistory.folderOverride = null;
    DataDirectory.current = oldData;
    temp.deleteSync(recursive: true);
  });

  Future<void> resume() async {
    control.resume();
    await control.ready;
    await _until(() => !control.manualControl);
  }

  test('every registered browser tool is gated, including no-tab reads', () async {
    final peer = await connect('First');
    BrowserTools.register();
    final listed = await ClaudeSdkTools.handle({
      'id': 1, 'method': 'tools/list',
    }, const ClaudeSdkCall(cwd: '/test'));
    final tools = ((listed['result'] as Map)['tools'] as List).cast<Map>();
    control.takeOver();
    await control.ready;
    for (final tool in tools.where((t) => '${t['name']}'.startsWith('browser_'))) {
      final response = await ClaudeSdkTools.handle({
        'id': 2, 'method': 'tools/call',
        'params': {'name': tool['name'], 'arguments': <String, Object?>{}},
      }, const ClaudeSdkCall(cwd: '/test', sessionId: 'other-session'));
      final result = response['result'] as Map;
      expect(result['isError'], isTrue, reason: '${tool['name']}');
      expect('${result['content']}', contains('paused'));
    }
    expect(peer.requests, isEmpty);
    // Human requests are not agent requests and stay usable during takeover.
    await peer.browser.request('tabs.list');
    expect(peer.requests.single['method'], 'tabs.list');
  });

  test('takeover during an await prevents later writes even after resume', () async {
    final peer = await connect('First');
    final continueRun = Completer<void>();
    final atAwait = Completer<void>();
    var denied = false;
    final run = control.runAgent<void>(sessionId: 'session', action: () async {
      await peer.browser.cdp(7, 'Input.dispatchMouseEvent', {'type': 'mousePressed'});
      atAwait.complete();
      await continueRun.future;
      try {
        await peer.browser.cdp(7, 'Input.dispatchMouseEvent', {'type': 'mouseReleased'});
      } on BrowserControlError {
        denied = true;
        rethrow;
      }
    });
    final failed = expectLater(run, throwsA(isA<BrowserControlError>()));
    await atAwait.future;
    control.takeOver();
    await resume();
    continueRun.complete();
    await failed;
    await _until(() => denied);
    expect(peer.commands('Input.dispatchMouseEvent'), hasLength(1));
    await control.runAgent(action: () => peer.browser.cdp(7, 'DOM.getDocument'));
    expect(peer.commands('DOM.getDocument'), hasLength(1));
  });

  test('a dispatched read result is suppressed across takeover and resume', () async {
    final peer = await connect('First');
    peer.heldMethods.add('DOM.getDocument');
    final read = control.runAgent(action: () => peer.browser.cdp(7, 'DOM.getDocument'));
    final failed = expectLater(read, throwsA(isA<BrowserControlError>()));
    await _until(() => peer.commands('DOM.getDocument').isNotEmpty);
    final request = peer.commands('DOM.getDocument').single;
    control.takeOver();
    await resume();
    peer.reply(request, {'root': 'PRIVATE MANUAL PAGE'});
    await failed;
    expect(peer.commands('DOM.getDocument'), hasLength(1));
  });

  test('cancelled runs and an already-cancelled call cannot write', () async {
    final peer = await connect('First');
    final cancel = Completer<void>();
    peer.heldMethods.add('Page.captureScreenshot');
    final run = control.runAgent(
      cancelled: cancel.future,
      action: () async {
        await peer.browser.cdp(7, 'Page.captureScreenshot');
        return peer.browser.cdp(7, 'Page.navigate', {'url': 'https://example.invalid'});
      },
    );
    final failed = expectLater(run, throwsA(isA<BrowserControlError>()));
    await _until(() => peer.commands('Page.captureScreenshot').isNotEmpty);
    cancel.complete();
    await failed;
    peer.reply(peer.commands('Page.captureScreenshot').single, {'data': 'secret'});
    final before = peer.requests.length;
    await expectLater(control.runAgent(
      cancelled: Future<void>.value(),
      action: () => peer.browser.request('tabs.create'),
    ), throwsA(isA<BrowserControlError>()));
    expect(peer.requests.length, before);
    expect(peer.commands('Page.navigate'), isEmpty);
  });

  test('a session stays on its connection, including disconnect and tab collisions', () async {
    final first = await connect('First');
    await control.runAgent(sessionId: 'one', action: () => first.browser.request('tabs.list'));
    final second = await connect('Second');
    control.selectTarget(BrowserTab(second.browser, 7));
    expect(control.resolveBrowser(sessionId: 'one'), same(first.browser));
    expect(control.resolveBrowser(sessionId: 'two'), same(second.browser));
    await expectLater(control.runAgent(
      sessionId: 'one',
      action: () => second.browser.cdp(7, 'Page.navigate'),
    ), throwsA(isA<BrowserControlError>()));
    expect(second.commands('Page.navigate'), isEmpty);
    first.socket.destroy();
    await _until(() => !first.browser.connected);
    expect(() => control.resolveBrowser(sessionId: 'one'), throwsA(isA<BrowserControlError>()));
    expect(control.resolveBrowser(sessionId: 'two'), same(second.browser));
  });

  test('ambiguous new sessions cannot silently select the newest host', () async {
    await connect('First');
    await connect('Second');
    await expectLater(control.runAgent(
      sessionId: 'new', action: () async => 'should not run',
    ), throwsA(isA<BrowserControlError>()));
    expect(peers.every((p) => p.requests.isEmpty), isTrue);
  });

  test('background bodies and console from the protected interval are discarded', () async {
    final peer = await connect('First');
    final tab = BrowserTab(peer.browser, 7);
    final records = BrowserRecords.instance;
    await records.watch(tab, explicit: true);
    peer.heldMethods.add('Network.getResponseBody');
    peer.event('Network.requestWillBeSent', {
      'requestId': 'before', 'type': 'Fetch',
      'timestamp': 1, 'wallTime': DateTime.now().millisecondsSinceEpoch / 1000,
      'request': {'url': 'https://example.invalid', 'method': 'GET', 'headers': {}},
    });
    peer.event('Network.loadingFinished', {
      'requestId': 'before', 'timestamp': 2, 'encodedDataLength': 10,
    });
    await _until(() => peer.commands('Network.getResponseBody').isNotEmpty);
    control.takeOver();
    await control.ready;
    final privateAt = DateTime.now().millisecondsSinceEpoch.toDouble();
    peer.event('Runtime.consoleAPICalled', {
      'type': 'error', 'timestamp': privateAt,
      'args': [{'type': 'string', 'value': 'PRIVATE LOGIN'}],
    });
    peer.reply(peer.commands('Network.getResponseBody').single, {'body': 'PRIVATE BODY'});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(records.console(tab), isEmpty);
    expect(records.requests(tab), isEmpty);
    await resume();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await records.watch(tab, explicit: true);
    // Runtime.enable may replay the manual-period cache after reattaching.
    peer.event('Runtime.consoleAPICalled', {
      'type': 'error', 'timestamp': privateAt,
      'args': [{'type': 'string', 'value': 'PRIVATE REPLAY'}],
    });
    peer.event('Runtime.consoleAPICalled', {
      'type': 'log', 'timestamp': DateTime.now().millisecondsSinceEpoch + 10,
      'args': [{'type': 'string', 'value': 'new observation'}],
    });
    await _until(() => records.console(tab).isNotEmpty);
    expect(records.console(tab).map((e) => e.text), ['new observation']);
    expect(records.requests(tab), isEmpty);
  });

  test('unknown-age events and unmatched header/socket replay fail closed', () async {
    final peer = await connect('First');
    final tab = BrowserTab(peer.browser, 7);
    final records = BrowserRecords.instance;
    await records.watch(tab, explicit: true);
    control.takeOver();
    await resume();
    await records.watch(tab, explicit: true);
    peer.event('Runtime.consoleAPICalled', {
      'type': 'error', 'args': [{'type': 'string', 'value': 'PRIVATE UNKNOWN AGE'}],
    });
    peer.event('Log.entryAdded', {'entry': {'level': 'error', 'text': 'PRIVATE LOG'}});
    peer.event('Network.requestWillBeSent', {
      'requestId': 'unproven', 'type': 'Fetch',
      'request': {'url': 'https://PRIVATE.invalid', 'method': 'GET', 'headers': {}},
    });
    peer.event('Network.webSocketCreated', {
      'requestId': 'socket', 'url': 'wss://PRIVATE.invalid',
    });
    peer.event('Network.requestWillBeSentExtraInfo', {
      'requestId': 'fresh', 'headers': {'PRIVATE': 'unmatched old header'},
    });
    peer.event('Network.requestWillBeSent', {
      'requestId': 'fresh', 'type': 'Fetch',
      'timestamp': 1, 'wallTime': DateTime.now().millisecondsSinceEpoch / 1000,
      'request': {'url': 'https://example.invalid/fresh', 'method': 'GET', 'headers': {}},
    });
    await _until(() => records.requests(tab).isNotEmpty);
    expect(records.console(tab), isEmpty);
    expect(records.requests(tab).map((r) => r.id), ['fresh']);
    expect(records.requests(tab).single.sentHeaders, isEmpty);
  });

  test('untimestamped dialogs are not recorded or auto-answered by a read call', () async {
    final peer = await connect('First');
    final tab = BrowserTab(peer.browser, 7);
    final records = BrowserRecords.instance;
    await records.watch(tab, explicit: true);
    final gate = Completer<void>();
    final started = Completer<void>();
    final reading = control.runAgent(action: () => records.acting(tab, () async {
      started.complete();
      await gate.future;
    }));
    await started.future;
    peer.event('Page.javascriptDialogOpening', {
      'type': 'alert', 'message': 'PRIVATE MANUAL DIALOG',
      'url': 'https://PRIVATE.invalid',
    });
    peer.event('Page.downloadWillBegin', {
      'guid': 'private', 'url': 'https://PRIVATE.invalid',
      'suggestedFilename': 'PRIVATE DOWNLOAD',
    });
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(records.dialogs(tab), isEmpty);
    expect(records.downloads(tab), isEmpty);
    expect(peer.commands('Page.handleJavaScriptDialog'), isEmpty);
    gate.complete();
    await reading;
    BrowserTools.register();
    final result = await ClaudeSdkTools.handle({
      'id': 1, 'method': 'tools/call',
      'params': {'name': 'browser_dialog', 'arguments': {'tabId': 7, 'accept': false}},
    }, const ClaudeSdkCall(cwd: '/test', sessionId: 'explicit-dialog'));
    expect((result['result'] as Map)['isError'], isNot(true));
    expect(peer.commands('Page.handleJavaScriptDialog'), hasLength(1));
    expect('${result['result']}', isNot(contains('PRIVATE')));
  });

  test('historical reveal requires this session and known connection provenance', () async {
    final first = await connect('First');
    final second = await connect('Second');
    BrowserTools.register();
    control.bindSession('reveal-first', BrowserTab(first.browser, 7));
    control.bindSession('reveal-second', BrowserTab(second.browser, 7));
    for (final session in ['reveal-first', 'reveal-second']) {
      final result = await ClaudeSdkTools.handle({
        'id': 1, 'method': 'tools/call',
        'params': {'name': 'browser_console', 'arguments': {'tabId': 7}},
      }, ClaudeSdkCall(cwd: '/test', sessionId: session));
      expect((result['result'] as Map)['isError'], isNot(true));
    }
    expect(BrowserTools.shownTarget(7, sessionId: 'reveal-first'), BrowserTab(first.browser, 7));
    expect(BrowserTools.shownTarget(7, sessionId: 'reveal-second'), BrowserTab(second.browser, 7));
    expect(BrowserTools.shownTarget(7, sessionId: 'old-persisted-session'), isNull);
    expect(BrowserTools.shownTarget(7), isNull);
    control.unbindSession('reveal-first'); // An explicit safe reset, not a picker change.
    control.bindSession('reveal-first', BrowserTab(second.browser, 7));
    await ClaudeSdkTools.handle({
      'id': 2, 'method': 'tools/call',
      'params': {'name': 'browser_console', 'arguments': {'tabId': 7}},
    }, const ClaudeSdkCall(cwd: '/test', sessionId: 'reveal-first'));
    expect(BrowserTools.shownTarget(7, sessionId: 'reveal-first'), isNull);
  });

  test('picker changes never reroute old-schema session or anonymous calls', () async {
    final first = await connect('First');
    final second = await connect('Second');
    BrowserTools.register();
    Future<void> evaluate(String? session) async {
      final response = await ClaudeSdkTools.handle({
        'id': 1, 'method': 'tools/call',
        'params': {'name': 'browser_evaluate', 'arguments': {'tabId': 7, 'expression': '1'}},
      }, ClaudeSdkCall(cwd: '/test', sessionId: session));
      expect((response['result'] as Map)['isError'], isNot(true));
    }
    control.selectTarget(BrowserTab(first.browser, 7));
    control.bindSession('sticky-tool', BrowserTab(first.browser, 7));
    await evaluate('sticky-tool');
    await evaluate(null);
    final before = first.commands('Runtime.evaluate').length;
    control.selectTarget(BrowserTab(second.browser, 7));
    control.bindSession('sticky-tool', BrowserTab(second.browser, 7));
    await evaluate('sticky-tool');
    await evaluate(null);
    expect(first.commands('Runtime.evaluate').length, before + 2);
    expect(second.commands('Runtime.evaluate'), isEmpty);
    first.socket.destroy();
    await _until(() => !first.browser.connected);
    expect(() => control.resolveBrowser(sessionId: 'sticky-tool'), throwsA(isA<BrowserControlError>()));
    expect(() => control.resolveBrowser(), throwsA(isA<BrowserControlError>()));
  });

  test('failed required cleanup keeps the gate closed until an acknowledged retry', () async {
    final peer = await connect('First');
    await control.runAgent(action: () => peer.browser.cdp(7, 'DOM.getDocument'));
    peer.errorMethods.add('Runtime.removeBinding');
    control.takeOver();
    await control.ready;
    control.resume();
    await control.ready;
    expect(control.manualControl, isTrue);
    expect(control.cleanupError, contains('Runtime.removeBinding'));
    await expectLater(control.runAgent(action: () => peer.browser.request('tabs.list')),
        throwsA(isA<BrowserControlError>()));
    peer.errorMethods.clear();
    await resume();
    expect(control.cleanupError, isNull);
  });

  test('native debugger cancellation stops later cleanup stages and reattach', () async {
    final peer = await connect('First');
    final tab = BrowserTab(peer.browser, 7);
    await control.runAgent(action: () => peer.browser.cdp(7, 'DOM.getDocument'));
    peer.heldMethods.add('Runtime.evaluate');
    control.takeOver();
    await _until(() => peer.commands('Runtime.evaluate').isNotEmpty);
    final stop = peer.commands('Runtime.evaluate').last;
    peer.send({'type': 'event', 'event': 'detached', 'tabId': 7,
      'reason': 'canceled_by_user'});
    await _until(() => control.isDetached(tab));
    peer.reply(stop, <String, Object?>{});
    await control.ready;
    expect(peer.commands('Runtime.removeBinding'), isEmpty);
    await resume();
    // Non-agent/root teardown and stale human continuations cannot reattach.
    await expectLater(Future.sync(() => peer.browser.cdp(7, 'DOM.getDocument')),
        throwsA(isA<BrowserControlError>()));
    await expectLater(control.runAgent(action: () => peer.browser.cdp(7, 'DOM.getDocument')),
        throwsA(isA<BrowserControlError>()));
    expect(peer.commands('DOM.getDocument'), hasLength(1));
    control.selectTarget(tab); // Restoring selection alone is not permission.
    expect(control.isDetached(tab), isTrue);
    control.bindSession('restored-session', tab);
    expect(control.isDetached(tab), isTrue);
    control.reconnectTab(tab); // A fresh explicit human reconnect is required.
    await control.runAgent(action: () => peer.browser.cdp(7, 'DOM.getDocument'));
    expect(peer.commands('DOM.getDocument'), hasLength(2));
  });

  test('repeated tracing start-stop-start is shut down on takeover', () async {
    final peer = await connect('First');
    await control.runAgent(action: () async {
      await peer.browser.cdp(7, 'Tracing.start');
      await peer.browser.cdp(7, 'Tracing.end');
      await peer.browser.cdp(7, 'Tracing.start');
    });
    control.takeOver();
    await control.ready;
    expect(peer.commands('Tracing.end'), hasLength(2));
  });

  test('resume waits for trace completion, not merely the end acknowledgement', () async {
    final peer = await connect('First');
    await control.runAgent(action: () => peer.browser.cdp(7, 'Tracing.start'));
    peer.traceCompleteOnEnd = false;
    control.takeOver();
    await _until(() => peer.commands('Tracing.end').isNotEmpty);
    control.resume();
    expect(control.manualControl, isTrue);
    expect(control.cleaningUp, isTrue);
    peer.event('Tracing.dataCollected', {'value': [{'name': 'PRIVATE OLD TRACE'}]});
    peer.event('Tracing.tracingComplete', <String, Object?>{});
    await control.ready;
    await _until(() => !control.manualControl);
  });

  test('manual state survives reload; unknown or unwritable state is fail-closed', () async {
    final flag = File(BrowserAgentControl.stateFilePath);
    control.takeOver();
    await control.ready;
    expect(flag.readAsStringSync().trim(), 'paused');
    control.resetForTesting(); // Reload only, never erases persisted flag.
    expect(control.manualControl, isTrue);
    await resume();
    expect(flag.readAsStringSync().trim(), 'paused');
    control.resetForTesting();
    expect(control.manualControl, isTrue);
    flag.writeAsStringSync('resumed'); // Legacy marker is never authority.
    control.resetForTesting();
    expect(control.manualControl, isTrue);
    flag.writeAsStringSync('corrupt state');
    control.resetForTesting();
    expect(control.manualControl, isTrue);
    expect(control.cleanupError, isNotNull);
    await resume();
    expect(control.manualControl, isFalse);
    flag.deleteSync();
    Directory(flag.path).createSync();
    control.resetForTesting();
    expect(control.manualControl, isTrue);
    control.resume();
    expect(control.manualControl, isTrue);
    expect(control.cleanupError, contains('could not be saved'));
    Directory(flag.path).deleteSync();
    await resume();
  });

  test('browser_watch ends on takeover and does not replay manual input', () async {
    final peer = await connect('First');
    final watching = await control.runAgent(action: () => BrowserWatching.start(
      BrowserTab(peer.browser, 7), 'test observation',
    ));
    expect(BrowserWatching.current.value, same(watching));
    control.takeOver();
    await control.ready;
    expect(watching.ended, isTrue);
    expect(BrowserWatching.current.value, isNull);
    await resume();
    peer.event('Runtime.bindingCalled', {
      'name': '__baoWatchStep',
      'payload': jsonEncode({'type': 'input', 'value': 'PRIVATE LOGIN'}),
    });
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(watching.steps, isEmpty);
    await expectLater(watching.report(finished: true), throwsA(isA<BrowserControlError>()));
    expect(peer.commands('Runtime.evaluate').any((r) =>
      '${(r['params'] as Map)['params']}'.contains('stop(true)')), isTrue);
  });
  test('persistent history keeps earlier records but never manual data or replay', () async {
    final peer = await connect('First');
    final tab = BrowserTab(peer.browser, 7);
    final records = BrowserRecords.instance;
    await records.watch(tab, explicit: true);
    final history = BrowserHistory.instance;
    history.detailed = true;
    history.start();
    addTearDown(history.stop);
    peer.send({'type': 'event', 'event': 'tab', 'tab': {
      'tabId': 7, 'url': 'https://example.invalid', 'title': 'Synthetic page',
    }});
    await _until(() => peer.commands('Page.addScriptToEvaluateOnNewDocument').isNotEmpty);
    final hook = peer.commands('Page.addScriptToEvaluateOnNewDocument').last;
    final source = '${((hook['params'] as Map)['params'] as Map)['source']}';
    final oldToken = RegExp("recording: '([^']+)'").firstMatch(source)![1]!;
    peer.event('Runtime.consoleAPICalled', {
      'type': 'error', 'timestamp': DateTime.now().millisecondsSinceEpoch + 1,
      'args': [{'type': 'string', 'value': 'allowed-before'}],
    });
    await _until(() => records.console(tab).isNotEmpty);
    final start = DateTime.now().subtract(const Duration(minutes: 1));
    await history.read(start, DateTime.now().add(const Duration(seconds: 1)), (_) => true);
    peer.event('Network.requestWillBeSent', {
      'requestId': 'userinfo', 'type': 'Fetch', 'timestamp': 1,
      'wallTime': DateTime.now().millisecondsSinceEpoch / 1000,
      'request': {'url': 'https://user%40example.com:secret%3Avalue@example.invalid/safe',
        'method': 'GET', 'headers': {'aUtHoRiZaTiOn': 'Bearer REDACT-ME', 'cOoKiE': 'REDACT-COOKIE'}},
    });
    peer.event('Network.responseReceived', {
      'requestId': 'userinfo', 'type': 'Fetch',
      'response': {'status': 200, 'mimeType': 'text/plain',
        'headers': {'SeT-CoOkIe': 'REDACT-RESPONSE-COOKIE'}},
    });
    peer.event('Network.loadingFinished', {
      'requestId': 'userinfo', 'timestamp': 2, 'encodedDataLength': 1,
    });
    await _until(() => records.requests(tab).any((r) => r.id == 'userinfo' && r.body != null));
    await history.read(start, DateTime.now().add(const Duration(seconds: 1)), (_) => true);
    peer.heldMethods.add('Network.getResponseBody');
    peer.event('Network.requestWillBeSent', {
      'requestId': 'history-pending', 'type': 'Fetch', 'timestamp': 1,
      'wallTime': DateTime.now().millisecondsSinceEpoch / 1000,
      'request': {'url': 'https://example.invalid/pending', 'method': 'GET', 'headers': {}},
    });
    peer.event('Network.loadingFinished', {
      'requestId': 'history-pending', 'timestamp': 2, 'encodedDataLength': 10,
    });
    await _until(() => peer.commands('Network.getResponseBody').length >= 2);
    control.takeOver();
    await control.ready;
    peer.reply(peer.commands('Network.getResponseBody').last,
      {'body': 'PRIVATE IN-FLIGHT BODY'});
    final privateAt = DateTime.now().millisecondsSinceEpoch.toDouble();
    peer.send({'type': 'event', 'event': 'tab', 'tab': {
      'tabId': 7, 'url': 'https://PRIVATE-MANUAL.invalid', 'title': 'PRIVATE TITLE',
    }});
    peer.event('Runtime.consoleAPICalled', {
      'type': 'error', 'timestamp': privateAt,
      'args': [{'type': 'string', 'value': 'PRIVATE CONSOLE'}],
    });
    peer.event('Runtime.bindingCalled', {
      'name': '__baoHistoryStep',
      'payload': jsonEncode({'type': 'input', 'recording': oldToken,
        'value': 'PRIVATE INPUT', 'time': privateAt}),
    });
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await resume();
    await records.watch(tab, explicit: true);
    peer.event('Runtime.consoleAPICalled', {
      'type': 'error', 'timestamp': privateAt,
      'args': [{'type': 'string', 'value': 'PRIVATE REPLAY'}],
    });
    peer.event('Runtime.bindingCalled', {
      'name': '__baoHistoryStep',
      'payload': jsonEncode({'type': 'input', 'recording': oldToken,
        'value': 'PRIVATE DELAYED INPUT', 'time': DateTime.now().millisecondsSinceEpoch}),
    });
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final kept = await history.read(start, DateTime.now().add(const Duration(seconds: 1)), (_) => true);
    final disk = jsonEncode(kept);
    expect(disk, contains('allowed-before'));
    expect(disk, isNot(contains('PRIVATE')));
    expect(disk, contains('https://example.invalid/safe'));
    expect(disk, isNot(contains('user%40example.com')));
    expect(disk, isNot(contains('secret%3Avalue')));
    expect(disk, isNot(contains('REDACT-')));
    expect(disk, contains('aUtHoRiZaTiOn'));
    expect(disk, contains('not kept'));
    expect(Directory(history.folder).listSync(recursive: true).whereType<File>(), isNotEmpty);
  });

}

Future<void> _until(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(done(), isTrue, reason: 'Synthetic host condition timed out');
}

/// Synthetic native host only. Never launches Chrome or uses a real profile.
class _NativePeer {
  _NativePeer(this.socket) {
    socket.listen(_read);
  }
  final Socket socket;
  late BrowserConnection browser;
  final requests = <Map<String, Object?>>[];
  final heldMethods = <String>{};
  final errorMethods = <String>{};
  bool traceCompleteOnEnd = true;
  final _buffer = BytesBuilder(copy: false);

  List<Map<String, Object?>> commands(String method) => requests.where((r) =>
      r['method'] == 'cdp' && (r['params'] as Map)['method'] == method).toList();

  void send(Map<String, Object?> message) {
    final body = utf8.encode(jsonEncode(message));
    socket
      ..add((ByteData(4)..setUint32(0, body.length, Endian.little)).buffer.asUint8List())
      ..add(body);
  }

  void reply(Map<String, Object?> request, Object? result) =>
      send({'id': request['id'], 'result': result});

  void event(String method, Map<String, Object?> params) => send({
    'type': 'event', 'event': 'cdp', 'tabId': 7,
    'method': method, 'params': params,
  });

  void _read(Uint8List data) {
    _buffer.add(data);
    final bytes = _buffer.takeBytes();
    var offset = 0;
    while (bytes.length - offset >= 4) {
      final length = ByteData.sublistView(bytes, offset, offset + 4)
          .getUint32(0, Endian.little);
      if (bytes.length - offset < 4 + length) break;
      final request = (jsonDecode(utf8.decode(
        bytes.sublist(offset + 4, offset + 4 + length),
      )) as Map).cast<String, Object?>();
      offset += 4 + length;
      requests.add(request);
      final params = request['params'] as Map;
      final method = params['method'] ?? request['method'];
      if (heldMethods.contains(method)) continue;
      if (errorMethods.contains(method)) {
        send({'id': request['id'], 'error': 'Synthetic failure: $method'});
        continue;
      }
      if (method == 'Tracing.end' && traceCompleteOnEnd) {
        event('Tracing.tracingComplete', <String, Object?>{});
      }
      // chrome.debugger.detach completes without an onDetach event.
      reply(request, switch (request['method']) {
        'tabs.list' => [{'tabId': 7, 'title': 'Synthetic page', 'url': 'https://example.invalid'}],
        'tabs.create' => {'tabId': 7},
        _ when method == 'Page.addScriptToEvaluateOnNewDocument' => {'identifier': 'fixture-script'},
        _ => <String, Object?>{},
      });
    }
    if (offset < bytes.length) _buffer.add(bytes.sublist(offset));
  }
}
