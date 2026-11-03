// Opt-in, local-only real Chrome for Testing smoke. Not a replacement for the
// synthetic widget suite or a native-host/extension end-to-end test.
//
// BAOCODE_REAL_CHROME_SMOKE=1 BAOCODE_CHROME_FOR_TESTING=/official/cft/chrome \
// BAOCODE_CFT_VERSION=<the exact downloaded version> \
//   flutter test test/browser/browser_takeover_real_chrome_test.dart
//
// The caller supplies an official CfT binary; this test downloads nothing,
// never opens a personal profile, and does not install an extension/host.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/browser/browser_agent_control.dart';
import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/browser/browser_records.dart';
import 'package:baocode/browser/browser_tools.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/real_chrome_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['BAOCODE_REAL_CHROME_SMOKE'] == '1';
  final executable = Platform.environment['BAOCODE_CHROME_FOR_TESTING'];
  final version = Platform.environment['BAOCODE_CFT_VERSION'];

  test('real Chrome takeover shuts down capture, permits human view, and '
      'requires a fresh recorder and explicit connection recovery',
      () => HttpOverrides.runWithHttpOverrides(() async {
    expect(executable, isNotNull, reason: 'Supply the official CfT executable.');
    expect(version, matches(RegExp(r'^\d+\.\d+\.\d+\.\d+$')),
        reason: 'Pin and record the official CfT version.');
    final root = Directory.systemTemp.createTempSync('bao-real-chrome-');
    final bridge = BrowserBridge.instance;
    final control = BrowserAgentControl.instance;
    final oldData = DataDirectory.current;
    final oldHome = BrowserBridge.home;
    final oldFolder = BrowserBridge.socketFolder;
    final oldLoopback = BrowserBridge.loopback;
    final oldHistory = BrowserHistory.folderOverride;
    DataDirectory.current = DataDirectory(p.join(root.path, 'app-data'));
    BrowserBridge.home = p.join(root.path, 'empty-home');
    BrowserBridge.socketFolder = root.path;
    BrowserBridge.loopback = true;
    BrowserHistory.folderOverride = p.join(root.path, 'history');
    control.resetForTesting();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/event') {
        response.headers.contentType = ContentType.json;
        response.write('{"fixture":true}');
      } else {
        response.headers.contentType = ContentType.html;
        response.write('''
<!doctype html><meta charset=utf-8><title>Disposable takeover fixture</title>
<label>Fixture input <input id=field></label>
<p id=out>Only local test data.</p>
<script>
window.fixtureTraffic = async function (marker) {
  console.log(marker);
  await fetch('/event?marker=' + encodeURIComponent(marker));
};
</script>
''');
      }
      await response.close();
    });
    final page = Uri.parse('http://127.0.0.1:${server.port}/');
    final chrome = RealChromeFixture(root, page);
    addTearDown(() async {
      String? cleanupError;
      try {
        BrowserTools.unregister();
        if (!control.manualControl) {
          control.takeOver();
        }
        await control.ready;
        cleanupError = control.cleanupError;
        BrowserWatching.current.value?.cancel();
      } finally {
        try {
          await chrome.close();
        } finally {
          await bridge.stop();
          await server.close(force: true);
          control.resetForTesting();
          BrowserBridge.home = oldHome;
          BrowserBridge.socketFolder = oldFolder;
          BrowserBridge.loopback = oldLoopback;
          BrowserHistory.folderOverride = oldHistory;
          DataDirectory.current = oldData;
          // Only this test's new data/profile. Windows Chrome can release a
          // final profile handle just after its main process exits.
          await chromeUntil(() {
            try {
              if (root.existsSync()) {
                root.deleteSync(recursive: true);
              }
              return true;
            } on FileSystemException {
              return false;
            }
          }, reason: 'Disposable Chrome profile could not be removed.');
        }
      }
      expect(cleanupError, isNull);
      expect(chrome.errors, isEmpty, reason: 'Late Chrome protocol errors after closure.');
    });
    await bridge.start();
    expect(bridge.otherApp, isFalse);
    await chrome.start(executable!, version!);
    await chromeUntil(() => bridge.browsers.length == 1);
    final browser = bridge.browsers.single;
    final tab = BrowserTab(browser, 1);
    const session = 'disposable-real-chrome-smoke';
    BrowserTools.register();
    var callId = 0;
    Future<Map> tool(String name, [Map<String, Object?> arguments = const {}]) async {
      final response = await ClaudeSdkTools.handle({
        'jsonrpc': '2.0', 'id': ++callId, 'method': 'tools/call',
        'params': {'name': name, 'arguments': arguments},
      }, ClaudeSdkCall(cwd: root.path, sessionId: session));
      return response['result'] as Map;
    }
    String text(Map result) => (result['content'] as List).cast<Map>()
        .where((item) => item['type'] == 'text')
        .map((item) => item['text']).join('\n');
    Future<Object?> humanEvaluate(String expression) async {
      final value = await browser.cdp(1, 'Runtime.evaluate', {
        'expression': expression, 'returnByValue': true, 'awaitPromise': true,
      });
      expect(value['exceptionDetails'], isNull);
      return (value['result'] as Map?)?['value'];
    }
    Future<void> humanType(String value) async {
      await humanEvaluate("field.value = ''; field.focus()");
      await browser.cdp(1, 'Input.insertText', {'text': value});
    }
    Future<void> resume() async {
      control.resume();
      await control.ready;
      await chromeUntil(() => !control.manualControl,
          reason: 'Resume remained paused: ${control.cleanupError}');
    }
    final records = BrowserRecords.instance;

    // A new application process never inherits permission to operate.
    expect(control.manualControl, isTrue);
    final initiallyDenied = await tool('browser_tabs');
    expect(initiallyDenied['isError'], isTrue);
    expect(text(initiallyDenied), contains('paused'));
    expect(chrome.commands, isEmpty);
    await resume();
    await chromeUntil(() async => await humanEvaluate(
      "document.readyState === 'complete' && typeof window.fixtureTraffic === 'function'",
    ) == true, reason: 'The local fixture document did not become ready.');
    final first = await tool('browser_evaluate', {
      'tabId': 1, 'expression': "fixtureTraffic('AUTHORIZED_BEFORE').then(() => 'ready')",
    });
    expect(first['isError'], isNot(true), reason: text(first));
    await chromeUntil(() => records.console(tab).any(
      (entry) => entry.text.contains('AUTHORIZED_BEFORE'),
    ));
    await chromeUntil(() => records.requests(tab).any(
      (request) => request.url.contains('AUTHORIZED_BEFORE'),
    ));

    final oldWatching = await control.runAgent(
      sessionId: session,
      action: () => BrowserWatching.start(tab, 'Record only fixture input'),
    );
    chrome.holdBindings = true;
    await humanType('OLD_GENERATION_EVENT');
    await chromeUntil(() => chrome.heldBindings.any(
      (event) => jsonEncode(event).contains('OLD_GENERATION_EVENT'),
    ));
    // These are actual Chrome binding payloads, delayed at the transport, not
    // fake protocol success responses or manufactured recorder generations.
    final oldEvent = chrome.heldBindings.firstWhere(
      (event) => jsonEncode(event).contains('OLD_GENERATION_EVENT'),
    );
    final oldPayload = jsonDecode((oldEvent['params'] as Map)['payload'] as String) as Map;
    expect(oldPayload['recording'], isNotEmpty);

    // Delay an actual, completed Chrome reply at the native transport. The
    // main-agent tool must be revoked even when that response arrives later.
    chrome.holdNextEvaluation = true;
    final lateTool = tool('browser_evaluate', {
      'tabId': 1, 'expression': "'PENDING_REAL_CDP_RESULT'",
    });
    await chromeUntil(() => chrome.heldEvaluation != null);
    final continueOldCall = Completer<void>();
    final oldCallEntered = Completer<void>();
    final oldCall = control.runAgent(sessionId: session, action: () async {
      oldCallEntered.complete();
      await continueOldCall.future;
      await browser.cdp(1, 'Input.insertText', {'text': 'REVOKED_LATE_WRITE'});
    });
    final oldCallRejected = expectLater(oldCall, throwsA(isA<BrowserControlError>()));
    await oldCallEntered.future;
    addTearDown(() {
      if (!continueOldCall.isCompleted) {
        continueOldCall.complete();
      }
    });

    // Leave a trusted input event in the recorder's real 800ms debounce queue.
    await humanType('QUEUED_BEFORE_TAKEOVER');
    final cleanupStart = chrome.commands.length;
    final clock = Stopwatch()..start();
    control.takeOver();
    await control.ready.timeout(const Duration(seconds: 10));
    clock.stop();
    expect(control.manualControl, isTrue);
    expect(control.cleaningUp, isFalse);
    expect(control.cleanupError, isNull, reason: '${chrome.errors}');
    expect(clock.elapsed, lessThan(const Duration(seconds: 10)));
    final revokedTool = await lateTool;
    expect(revokedTool['isError'], isTrue);
    expect(text(revokedTool), isNot(contains('PENDING_REAL_CDP_RESULT')));
    await oldCallRejected;
    expect(oldWatching.ended, isTrue);
    expect(oldWatching.steps, isEmpty);
    expect(chrome.detaches, 1);
    for (final method in [
      'Runtime.removeBinding', 'Network.disable', 'Log.disable',
      'Runtime.disable', 'Page.disable', 'Performance.disable',
      'Target.setAutoAttach',
    ]) {
      expect(chrome.commands.skip(cleanupStart), contains(method));
      expect(chrome.acknowledgements, contains(method),
          reason: 'Real Chrome must acknowledge $method, not a stub.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    expect(chrome.events.where((event) =>
        event['method'] == 'Runtime.bindingCalled' &&
        jsonEncode(event).contains('QUEUED_BEFORE_TAKEOVER')), isEmpty);

    // Human mirror-equivalent requests have no agent lease. Chrome really
    // reattaches, renders pixels, and accepts trusted input while AI is paused.
    final attachmentsBeforeHuman = chrome.attaches;
    final shot = await browser.cdp(1, 'Page.captureScreenshot', {'format': 'png'});
    expect(base64Decode(shot['data'] as String).length, greaterThan(100));
    expect(chrome.attaches, attachmentsBeforeHuman + 1);
    await humanType('MANUAL_INTERVAL_INPUT');
    expect(await humanEvaluate('field.value'), 'MANUAL_INTERVAL_INPUT');
    await humanEvaluate("fixtureTraffic('MANUAL_INTERVAL_TRAFFIC')");
    expect(await humanEvaluate('typeof window.__baoWatch'), 'undefined');
    final denied = await tool('browser_evaluate', {
      'tabId': 1, 'expression': "document.title = 'SHOULD_NOT_EXECUTE'",
    });
    expect(denied['isError'], isTrue);
    expect(text(denied), contains('paused'));
    expect(await humanEvaluate('document.title'), 'Disposable takeover fixture');

    // Runtime.enable can replay Chrome's console history. The desktop must
    // reject old timestamps as well as old binding-generation payloads.
    await resume();
    final inputCommandsBeforeLate = chrome.commands.where(
      (name) => name == 'Input.insertText',
    ).length;
    chrome.releaseEvaluation();
    continueOldCall.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(chrome.commands.where((name) => name == 'Input.insertText').length,
        inputCommandsBeforeLate, reason: 'Resume never revives an old agent call.');
    final after = await tool('browser_evaluate', {
      'tabId': 1, 'expression': "fixtureTraffic('AUTHORIZED_AFTER').then(() => 'ready')",
    });
    expect(after['isError'], isNot(true), reason: text(after));
    final freshWatching = await control.runAgent(
      sessionId: session,
      action: () => BrowserWatching.start(tab, 'A new authorized fixture recording'),
    );
    chrome.releaseBindings();
    await humanType('NEW_GENERATION_INPUT');
    await chromeUntil(() => freshWatching.steps.any(
      (step) => step.value == 'NEW_GENERATION_INPUT',
    ));
    await chromeUntil(() => records.console(tab).any(
      (entry) => entry.text.contains('AUTHORIZED_AFTER'),
    ));
    await chromeUntil(() => records.requests(tab).any(
      (request) => request.url.contains('AUTHORIZED_AFTER'),
    ));
    expect(freshWatching.steps.any((step) =>
        '${step.value}'.contains('OLD_GENERATION') ||
        '${step.value}'.contains('QUEUED_BEFORE') ||
        '${step.value}'.contains('MANUAL_INTERVAL')), isFalse);
    expect(records.console(tab).any(
      (entry) => entry.text.contains('MANUAL_INTERVAL'),
    ), isFalse);
    expect(records.requests(tab).any(
      (request) => request.url.contains('MANUAL_INTERVAL'),
    ), isFalse);
    final newEvent = chrome.events.lastWhere((event) =>
        event['method'] == 'Runtime.bindingCalled' &&
        jsonEncode(event).contains('NEW_GENERATION_INPUT'));
    final newPayload = jsonDecode((newEvent['params'] as Map)['payload'] as String) as Map;
    expect(newPayload['recording'], isNot(oldPayload['recording']));

    // Same conversation recovery is explicitly allowed only after its original
    // native connection dies. A new connection never silently takes over it.
    expect(control.canRebindSession(session, tab), isFalse);
    chrome.holdNextEvaluation = true;
    final oldConnectionTool = tool('browser_evaluate', {
      'tabId': 1, 'expression': "'OLD_CONNECTION_RESPONSE'",
    });
    await chromeUntil(() => chrome.heldEvaluation != null);
    control.takeOver();
    await control.ready;
    chrome.disconnectNative();
    await chromeUntil(() => !browser.connected);
    await chrome.connectNative();
    await chromeUntil(() => bridge.browsers.length == 1);
    final replacement = bridge.browsers.single;
    final discardedBefore = chrome.discardedStaleReplies;
    chrome.releaseEvaluation();
    expect(chrome.discardedStaleReplies, discardedBefore + 1,
        reason: 'A delayed response must stay bound to its original socket.');
    expect((await oldConnectionTool)['isError'], isTrue);
    expect(replacement, isNot(same(browser)));
    expect(() => control.resolveBrowser(sessionId: session),
        throwsA(isA<BrowserControlError>()));
    final replacementTab = BrowserTab(replacement, 1);
    control.selectTarget(replacementTab);
    expect(control.canRebindSession(session, replacementTab), isTrue);
    control.rebindSession(session, replacementTab);
    expect(control.resolveBrowser(sessionId: session), same(replacement));
    expect(control.manualControl, isTrue, reason: 'Rebind is not Resume.');
    await resume();
    final recovered = await tool('browser_evaluate', {
      'tabId': 1, 'expression': "'explicitly recovered'",
    });
    expect(recovered['isError'], isNot(true), reason: text(recovered));
    expect(text(recovered), contains('explicitly recovered'));
    expect(chrome.errors, isEmpty, reason: 'Late/real protocol errors must fail the smoke.');
    // ignore: avoid_print
    print('PASS: CfT $version; real domain shutdown in ${clock.elapsedMilliseconds}ms; '
        '${chrome.attaches} real CDP attachments; no old input/console/network backfill. '
        'Native-host discovery, chrome.debugger, and widget rendering are not covered.');
  }, _LoopbackHttpOverrides()),
    skip: enabled ? false : 'BAOCODE_REAL_CHROME_SMOKE=1 not set',
    timeout: const Timeout(Duration(minutes: 3)));
}

// Flutter's test HttpClient returns 400 rather than opening a socket. This
// opt-in integration zone uses real HTTP/WebSocket transport, restricted to
// numeric IPv4 loopback. Global test overrides are never changed, and proxy
// environment variables cannot route the fixture traffic off this machine.
class _LoopbackHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if ((uri.scheme != 'http' && uri.scheme != 'ws') ||
          uri.host != '127.0.0.1' ||
          uri.port <= 0 ||
          uri.userInfo.isNotEmpty ||
          proxyHost != null ||
          proxyPort != null) {
        throw StateError('Real Chrome smoke blocked non-loopback transport.');
      }
      return Socket.startConnect(InternetAddress.loopbackIPv4, uri.port);
    };
    return client;
  }
}
