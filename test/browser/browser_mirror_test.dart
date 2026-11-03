import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/browser/browser_agent_control.dart';
import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/browser/browser_mirror.dart';
import 'package:baocode/browser/browser_tools.dart';
import 'package:baocode/ide/ide_hover.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// Real one-pixel RGBA PNGs. The mirror decodes the image independently of
// the requested screencast format, so no Chrome or JPEG encoder is needed.
const _red =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';
const _blue =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/5ncLrgAAAABJRU5ErkJggg==';

void main() {
  // Its socket queue is real asynchronous work, outside widget fake time.
  final bridge = BrowserBridge.instance;
  setUp(() => expect(bridge.browsers, isEmpty));

  testWidgets('a burst is acknowledged but renders only its newest frame', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      await mirror.frames([const _Frame(_red, Size(800, 400))]);
      await tester.pump();
      expect(mirror.imageBytes, orderedEquals(base64Decode(_red)));

      final before = mirror.imageBytes;
      await mirror.frames([
        for (var i = 0; i < 99; i++) const _Frame(_red, Size(800, 400)),
        const _Frame(_blue, Size(400, 800)),
      ]);
      // All 100 frames reached the real listener, but no render was pumped.
      expect(mirror.imageBytes, same(before));
      await tester.pump();
      expect(mirror.imageBytes, orderedEquals(base64Decode(_blue)));
      expect(find.byType(Image), findsOneWidget);
      final page = tester.getRect(mirror.pageListener);
      final drawn = tester.getRect(find.byType(Image));
      expect(drawn.top, page.top);
      expect(drawn.height, closeTo(page.height, 0.001));
      expect(drawn.width, closeTo(page.height / 2, 0.001));
      expect(drawn.center.dx, closeTo(page.center.dx, 0.001));
    });
  });

  testWidgets('agent last-tab changes do not retarget the pinned mirror', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      await mirror.frames([const _Frame(_red, Size(800, 400))]);
      await tester.pump();
      mirror.host.calls.clear();

      BrowserTools.lastTab.value = BrowserTab(mirror.connection, 2);
      await tester.pump();
      await mirror.io(() async {
        mirror.host.sendFrame(const _Frame(_blue, Size(400, 800)), tabId: 2);
        await mirror.connection.request('test.barrier');
      });
      await tester.pump();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('browser-panel-address')),
      );
      expect(field.controller!.text, 'https://one.example/');
      expect(mirror.imageBytes, orderedEquals(base64Decode(_red)));
      expect(mirror.selected, [BrowserTab(mirror.connection, 1)]);
      expect(mirror.host.calls.where((call) => call.tabId == 2), isEmpty);
    });
  });

  testWidgets('blank margins reject input and pointer cancel releases a drag', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      await mirror.frames([const _Frame(_blue, Size(400, 800))]);
      await tester.pump();
      final page = tester.getRect(mirror.pageListener);
      final margin = page.topLeft + Offset(2, page.height / 2);
      mirror.host.calls.clear();

      await tester.tapAt(margin);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: margin, scrollDelta: const Offset(0, 30)),
      );
      await mirror.barrier();
      expect(mirror.mouseCalls, isEmpty);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Image)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(margin);
      await gesture.cancel();
      await mirror.until(
        () => mirror.mouseCalls.any(
          (call) => call.params['type'] == 'mouseReleased',
        ),
      );
      final press = mirror.mouseCalls.singleWhere(
        (call) => call.params['type'] == 'mousePressed',
      );
      final release = mirror.mouseCalls.singleWhere(
        (call) => call.params['type'] == 'mouseReleased',
      );
      expect(press.tabId, 1);
      expect(release.tabId, 1);
      expect(release.params['button'], 'left');
      expect(release.params['buttons'], 0);
      expect(release.params['x'], 0);
      expect(release.params['y'], closeTo(400, 0.001));

      await tester.pumpWidget(const SizedBox.shrink());
      await mirror.barrier();
      expect(
        mirror.mouseCalls.where((call) => call.params['type'] == 'mouseReleased'),
        hasLength(1),
        reason: 'cancel cleared the capture; disposal must not release twice',
      );
    });
  });

  testWidgets('hidden TickerMode stops polling and resumes capture when shown', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      await mirror.pump(visible: false);
      await mirror.until(
        () => mirror.host.callsFor('Page.stopScreencast').isNotEmpty,
      );
      mirror.host.calls.clear();
      await tester.pump(const Duration(seconds: 3));
      await mirror.barrier();
      expect(mirror.host.callsFor('Page.getLayoutMetrics'), isEmpty);
      expect(mirror.host.callsFor('Page.captureScreenshot'), isEmpty);
      expect(mirror.host.callsFor('Page.startScreencast'), isEmpty);

      await mirror.pump(visible: true);
      await mirror.until(
        () => mirror.host.callsFor('Page.startScreencast').isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await mirror.until(
        () => mirror.host.callsFor('Page.captureScreenshot').isNotEmpty,
      );
      await mirror.barrier();
      await tester.pump();
      expect(mirror.imageBytes, orderedEquals(base64Decode(_blue)));
    });
  });

  testWidgets('a screenshot from an old capture epoch cannot replace a new stream', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      mirror.host.holdScreenshots = true;
      await tester.pump(const Duration(milliseconds: 200));
      await mirror.until(() => mirror.host.pendingScreenshots.isNotEmpty);

      await mirror.pump(visible: false);
      await mirror.barrier();
      mirror.host.calls.clear();
      await mirror.pump(visible: true);
      await mirror.until(
        () => mirror.host.callsFor('Page.startScreencast').isNotEmpty,
      );
      await mirror.frames([const _Frame(_blue, Size(400, 800))]);
      await tester.pump();
      final current = mirror.imageBytes;

      await mirror.io(() async {
        mirror.host.completeScreenshots(_red);
        await mirror.connection.request('test.barrier');
      });
      await tester.pump();
      expect(mirror.imageBytes, same(current));
      expect(mirror.imageBytes, orderedEquals(base64Decode(_blue)));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('external detach stays silent until explicit Reconnect', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      final control = BrowserAgentControl.instance;
      final target = BrowserTab(mirror.connection, 1);
      expect(control.manualControl, isTrue);
      mirror.host.holdScreenshots = true;
      await tester.pump(const Duration(milliseconds: 200));
      await mirror.until(() => mirror.host.pendingScreenshots.isNotEmpty);
      await mirror.frames([const _Frame(_blue, Size(400, 800))]);
      await tester.pump();
      final beforeDetach = mirror.imageBytes;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Image)),
        kind: PointerDeviceKind.mouse,
      );
      await mirror.until(
        () => mirror.mouseCalls.any(
          (call) => call.params['type'] == 'mousePressed',
        ),
      );
      await mirror.barrier();
      mirror.host.calls.clear();

      void expectNoCdp(String phase) {
        expect(
          mirror.host.calls.where((call) => call.request['method'] == 'cdp'),
          isEmpty,
          reason: phase,
        );
        expect(control.isDetached(target), isTrue, reason: phase);
      }

      await mirror.io(() async {
        mirror.host.send({
          'type': 'event',
          'event': 'detached',
          'tabId': 1,
          'reason': 'canceled_by_user',
        });
        // A frame already in transit must not even be acknowledged: doing
        // so could attach the debugger again after the user cancelled it.
        mirror.host.sendFrame(const _Frame(_red, Size(800, 400)));
        await mirror.connection.request('test.barrier');
      });
      await tester.pump();
      expectNoCdp('detach and stale frame must not release, ACK, or reattach');
      expect(mirror.imageBytes, same(beforeDetach));

      await gesture.cancel();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await mirror.barrier();
      expectNoCdp('capture cancellation, keyboard input, and blur stay local');

      await mirror.pump(visible: false, ratio: 2);
      await tester.pump(const Duration(milliseconds: 200));
      await mirror.pump(visible: true, ratio: 2);
      await tester.pump(const Duration(seconds: 2));
      await mirror.barrier();
      expectNoCdp('visibility, DPR debounce, and polling cannot reconnect');

      await mirror.io(() async {
        mirror.host.completeScreenshots(_red);
        mirror.host.sendFrame(const _Frame(_red, Size(800, 400)));
        await mirror.connection.request('test.barrier');
      });
      await tester.pump();
      expectNoCdp('late screenshot completion and further frames stay inert');
      expect(mirror.imageBytes, same(beforeDetach));

      final reconnect = find.byWidgetPredicate(
        (widget) => widget is IdeActionButton && widget.tooltip == 'Reconnect',
      );
      expect(reconnect, findsOneWidget);

      // Restoring a saved panel selection is passive, even if the entire
      // widget and its controller are recreated. It cannot undo cancellation.
      final previousState = tester.state(find.byType(BrowserMirror));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await mirror.barrier();
      expect(find.byType(BrowserMirror), findsNothing);
      expectNoCdp('unmount must not send teardown to the cancelled debugger');

      await mirror.pump(ratio: 2);
      await mirror.until(() => reconnect.evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      await mirror.barrier();
      expect(tester.state(find.byType(BrowserMirror)), isNot(same(previousState)));
      expect(reconnect, findsOneWidget);
      expectNoCdp('remounting the saved initialTab must preserve cancellation');
      final restoredAddress = tester.widget<TextField>(
        find.byKey(const ValueKey('browser-panel-address')),
      );
      expect(restoredAddress.controller!.text, 'https://one.example/');

      await tester.tap(reconnect);
      await mirror.until(
        () => mirror.host.callsFor('Page.startScreencast').isNotEmpty,
      );
      expect(control.isDetached(target), isFalse);
      expect(control.manualControl, isTrue, reason: 'Reconnect is not Resume');
      await mirror.frames([const _Frame(_red, Size(800, 400))]);
      await tester.pump();
      expect(mirror.imageBytes, orderedEquals(base64Decode(_red)));
    });
  });

  for (final paused in [true, false]) {
    testWidgets(
      'Reconnect this chat changes only the dead binding while '
      '${paused ? 'paused' : 'resumed'}',
      (tester) async {
        await _withMirror(tester, (mirror) async {
          const sessionId = 'mirror-widget-test';
          final control = BrowserAgentControl.instance;
          final original = mirror.connection;
          if (!paused) {
            await tester.tap(find.text('Resume agent'));
            await tester.pump();
          }
          expect(control.manualControl, paused);
          expect(control.resolveBrowser(sessionId: sessionId), same(original));

          final (replacementHost, replacement) = await mirror.connectHost(
            'Replacement Chrome',
          );
          final target = BrowserTab(replacement, 1);
          expect(replacement, isNot(same(original)));
          await mirror.pump(initialTab: target);
          await mirror.until(
            () => replacementHost.callsFor('Page.startScreencast').isNotEmpty,
          );
          // Both connections expose tab 1. Viewing the second must not
          // silently replace this chat's original connection binding.
          expect(mirror.selected.last, target);
          expect(control.resolveBrowser(sessionId: sessionId), same(original));
          expect(find.textContaining('Agent is bound to'), findsOneWidget);
          expect(find.textContaining('explicitly shared tabs'), findsOneWidget);
          expect(find.text('Reconnect this chat'), findsNothing);

          await mirror.io(() async {
            mirror.host.destroy();
            await _waitUntil(() => !original.connected);
          });
          await mirror.until(
            () => find.text('Reconnect this chat').evaluate().isNotEmpty,
          );
          expect(control.canRebindSession(sessionId, target), isTrue);
          expect(
            () => control.resolveBrowser(sessionId: sessionId),
            throwsA(isA<BrowserControlError>()),
            reason: 'disconnect alone cannot fall back to the visible browser',
          );

          await tester.tap(find.text('Reconnect this chat'));
          await mirror.until(() => !control.canRebindSession(sessionId, target));
          expect(find.text('Reconnect this chat'), findsNothing);
          expect(find.textContaining('Agent is bound to'), findsNothing);
          expect(control.resolveBrowser(sessionId: sessionId), same(replacement));
          expect(control.manualControl, paused);

          BrowserConnection? routed;
          Future<void> probe() => control.runAgent<void>(
            sessionId: sessionId,
            action: () async {
              final browser = BrowserAgentControl.currentLease!.browser!;
              routed = browser;
              await browser.cdp(1, 'Runtime.evaluate', {
                'expression': '"reconnected-chat-test"',
              });
            },
          );

          if (paused) {
            await expectLater(probe(), throwsA(isA<BrowserControlError>()));
            expect(routed, isNull, reason: 'Reconnect this chat is not Resume');
            await tester.tap(find.text('Resume agent'));
            await tester.pump();
          }
          await mirror.io(probe);
          expect(routed, same(replacement));
          final probes = replacementHost.callsFor('Runtime.evaluate').where(
            (call) => call.params['expression'] == '"reconnected-chat-test"',
          );
          expect(probes, hasLength(1));
          expect(probes.single.tabId, 1);
          expect(
            mirror.host.callsFor('Runtime.evaluate').where(
              (call) => call.params['expression'] == '"reconnected-chat-test"',
            ),
            isEmpty,
          );
        });
      },
    );
  }
}

Future<void> _withMirror(
  WidgetTester tester,
  Future<void> Function(_MirrorHarness) test,
) async {
  final mirror = _MirrorHarness(tester);
  try {
    await mirror.open();
    await test(mirror);
  } finally {
    await mirror.close();
  }
}

class _MirrorHarness {
  _MirrorHarness(this.tester);

  final WidgetTester tester;
  final bridge = BrowserBridge.instance;
  final oldHome = BrowserBridge.home;
  final oldSocketFolder = BrowserBridge.socketFolder;
  final oldLoopback = BrowserBridge.loopback;
  final oldDataDirectory = DataDirectory.current;
  final oldLastTab = BrowserTools.lastTab.value;
  final selected = <BrowserTab>[];
  Directory? _temporary;
  _SocketHost? _host;
  final _additionalHosts = <_SocketHost>[];
  _SocketHost get host => _host!;
  late BrowserConnection connection;

  Finder get pageListener => find.descendant(
    of: find.byType(BrowserMirror),
    matching: find.byWidgetPredicate(
      (widget) => widget is Listener &&
          widget.onPointerHover != null &&
          widget.onPointerPanZoomUpdate != null,
    ),
  );

  Uint8List get imageBytes =>
      (tester.widget<Image>(find.byType(Image)).image as MemoryImage).bytes;

  List<_Call> get mouseCalls => host.callsFor('Input.dispatchMouseEvent');

  Future<void> io(Future<void> Function() action) async {
    await tester.runAsync(action);
  }

  Future<void> open() async {
    _temporary = Directory.systemTemp.createTempSync('bao-mirror-');
    BrowserBridge.home = p.join(_temporary!.path, 'empty-home');
    BrowserBridge.socketFolder = _temporary!.path;
    BrowserBridge.loopback = true;
    DataDirectory.current = DataDirectory(p.join(_temporary!.path, 'data'));
    BrowserAgentControl.instance.resetForTesting();
    BrowserTools.lastTab.value = null;
    await io(() async {
      await bridge.start();
      _host = await _SocketHost.connect();
      await _waitUntil(() => bridge.browsers.length == 1);
      connection = bridge.browsers.single;
    });
    await pump();
    await until(() => host.callsFor('Page.startScreencast').isNotEmpty);
    // Finish the initial layout's resize debounce without firing the 300 ms
    // polling timer. Tests then control when fallback screenshots can start.
    final starts = host.callsFor('Page.startScreencast').length;
    await tester.pump(const Duration(milliseconds: 200));
    await until(() => host.callsFor('Page.startScreencast').length > starts);
    await io(() async {
      final context = tester.element(find.byType(BrowserMirror));
      await precacheImage(MemoryImage(base64Decode(_red)), context);
      await precacheImage(MemoryImage(base64Decode(_blue)), context);
    });
  }

  Future<(_SocketHost, BrowserConnection)> connectHost(String name) async {
    late _SocketHost added;
    late BrowserConnection browser;
    await io(() async {
      added = await _SocketHost.connect(browserName: name);
      _additionalHosts.add(added);
      await _waitUntil(() => bridge.browsers.any((entry) => entry.browser == name));
      browser = bridge.browsers.singleWhere((entry) => entry.browser == name);
    });
    return (added, browser);
  }

  Future<void> pump({
    bool visible = true,
    double ratio = 1,
    BrowserTab? initialTab,
  }) => tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(devicePixelRatio: ratio),
        child: child!,
      ),
      home: Scaffold(
        body: TickerMode(
          enabled: visible,
          child: BrowserMirror(
            key: const ValueKey('test-browser-mirror'),
            sessionId: 'mirror-widget-test',
            initialTab: initialTab ?? BrowserTab(connection, 1),
            onSelectionChanged: selected.add,
          ),
        ),
      ),
    ),
  );

  Future<void> until(bool Function() done) async {
    for (var attempt = 0; attempt < 100 && !done(); attempt++) {
      await tester.pump();
      await io(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(done(), isTrue, reason: 'synthetic browser did not receive the request');
    await tester.pump();
  }

  Future<void> barrier() => io(() async {
    await connection.request('test.barrier');
  });

  Future<void> frames(List<_Frame> frames) => io(() async {
    final acknowledged = host.callsFor('Page.screencastFrameAck').length;
    for (final frame in frames) {
      host.sendFrame(frame);
    }
    // No widget pump here: assert batching before allowing a render frame.
    await _waitUntil(
      () => host.callsFor('Page.screencastFrameAck').length ==
          acknowledged + frames.length,
    );
  });

  Future<void> close() async {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      // Flush the focus/click check timers after disposing the mirror itself.
      await tester.pump(const Duration(milliseconds: 100));
      await io(() async {
        final hosts = [?_host, ..._additionalHosts];
        try {
          for (final host in hosts) {
            host.completeScreenshots(_red);
          }
          // A reply proves preceding outbound messages arrived without
          // binding either duplex socket's sink with an explicit flush.
          for (final browser in bridge.browsers) {
            await browser.request('test.barrier');
          }
        } finally {
          await bridge.stop();
          for (final host in hosts) {
            host.destroy();
          }
        }
      });
      // Let completed CDP futures cancel their request timeout timers.
      await tester.pump();
    } finally {
      BrowserAgentControl.instance.resetForTesting();
      BrowserTools.lastTab.value = oldLastTab;
      BrowserBridge.home = oldHome;
      BrowserBridge.socketFolder = oldSocketFolder;
      BrowserBridge.loopback = oldLoopback;
      DataDirectory.current = oldDataDirectory;
      _temporary?.deleteSync(recursive: true);
    }
  }
}

Future<void> _waitUntil(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'synthetic browser handshake or frame timed out');
}

class _Frame {
  const _Frame(this.data, this.size);

  final String data;
  final Size size;
}

class _Call {
  _Call(this.request);

  final Map<String, Object?> request;
  Map<String, Object?> get outerParams =>
      (request['params'] as Map).cast<String, Object?>();
  String get method => request['method'] == 'cdp'
      ? outerParams['method'] as String
      : request['method'] as String;
  int? get tabId => outerParams['tabId'] as int?;
  Map<String, Object?> get params => request['method'] == 'cdp'
      ? (outerParams['params'] as Map).cast<String, Object?>()
      : outerParams;
}

/// A native host speaking only to this test's real bridge over loopback.
class _SocketHost {
  _SocketHost(this.socket) {
    socket.listen(_read);
  }

  final Socket socket;
  final calls = <_Call>[];
  final pendingScreenshots = <Map<String, Object?>>[];
  final _buffer = <int>[];
  var holdScreenshots = false;
  var _frameId = 0;

  static Future<_SocketHost> connect({
    String browserName = 'Synthetic Chrome',
  }) async {
    final [port, token] = File(BrowserBridge.portPath)
        .readAsStringSync()
        .split(' ');
    final host = _SocketHost(
      await Socket.connect(InternetAddress.loopbackIPv4, int.parse(port)),
    );
    host.send({
      'type': 'hello',
      'origin': 'chrome-extension://${BrowserBridge.extensionIds.first}/',
      'token': token,
    });
    host.send({
      'type': 'hello',
      'browser': browserName,
      'protocol': BrowserBridge.protocol,
    });
    return host;
  }

  List<_Call> callsFor(String method) =>
      calls.where((call) => call.method == method).toList();

  void send(Map<String, Object?> message) {
    // Do not flush this live duplex sink: _read can write a reply while
    // flush temporarily binds it. Handshake, ACKs and reply barriers below
    // establish delivery without racing those writes.
    final body = utf8.encode(jsonEncode(message));
    socket
      ..add(
        (ByteData(4)..setUint32(0, body.length, Endian.little))
            .buffer
            .asUint8List(),
      )
      ..add(body);
  }

  void sendFrame(_Frame frame, {int tabId = 1}) => send({
    'type': 'event',
    'event': 'cdp',
    'tabId': tabId,
    'method': 'Page.screencastFrame',
    'params': {
      'sessionId': ++_frameId,
      'data': frame.data,
      'metadata': {
        'deviceWidth': frame.size.width,
        'deviceHeight': frame.size.height,
      },
    },
  });

  void _read(Uint8List bytes) {
    _buffer.addAll(bytes);
    while (_buffer.length >= 4) {
      final length = ByteData.sublistView(
        Uint8List.fromList(_buffer.sublist(0, 4)),
      ).getUint32(0, Endian.little);
      if (_buffer.length < length + 4) return;
      final request = (jsonDecode(
        utf8.decode(_buffer.sublist(4, length + 4)),
      ) as Map).cast<String, Object?>();
      _buffer.removeRange(0, length + 4);
      final call = _Call(request);
      calls.add(call);
      if (call.method == 'Page.captureScreenshot' && holdScreenshots) {
        pendingScreenshots.add(request);
        continue;
      }
      final Object result = switch (call.method) {
        'tabs.list' => [
          {'tabId': 1, 'title': 'Human page', 'url': 'https://one.example/'},
          {'tabId': 2, 'title': 'Agent page', 'url': 'https://two.example/'},
        ],
        'Page.getLayoutMetrics' => {
          'cssVisualViewport': {
            'pageX': 0,
            'pageY': 0,
            'clientWidth': 400,
            'clientHeight': 800,
          },
        },
        'Page.captureScreenshot' => {'data': _blue},
        'Runtime.evaluate' => {'result': {'value': false}},
        _ => <String, Object?>{},
      };
      send({'id': request['id'], 'result': result});
    }
  }

  void completeScreenshots(String data) {
    for (final request in pendingScreenshots) {
      send({'id': request['id'], 'result': {'data': data}});
    }
    pendingScreenshots.clear();
  }

  void destroy() => socket.destroy();
}
