// Opt-in BrowserMirror -> native bridge -> disposable real Chrome input smoke.
// The click oracle is the marker in Flutter's PAINTED pixels and real DOM
// events, never browserPagePoint, browserFrameRect, or another input transform.
// See fixtures/REAL_CHROME_SMOKE.md for official CfT provenance requirements.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:baocode/browser/browser_agent_control.dart';
import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/browser/browser_mirror.dart';
import 'package:baocode/browser/browser_tools.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/real_chrome_fixture.dart';

void main() {
  // Its initial Future.value queue must be created before testWidgets enters
  // FakeAsync, otherwise awaiting start in real I/O can deadlock that queue.
  final bridge = BrowserBridge.instance;
  final enabled = Platform.environment['BAOCODE_REAL_CHROME_SMOKE'] == '1';
  for (final zoom in [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('painted browser target receives real input at browser zoom $zoom',
        (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final mirror = _RealMirror(tester, bridge);
        try {
          await mirror.open(zoom);
          for (final ratio in [1.0, 1.25, 1.5, 2.0]) {
            for (final panel in [const Size(360, 620), const Size(960, 480)]) {
              final label = 'zoom=$zoom Flutter DPR=$ratio panel=$panel';
              await mirror.pump(panel, ratio);
              await mirror.showNewMarker();
              await mirror.checkPaintedInput(label);
              await mirror.checkLetterbox(label);
            }
          }

          // An off-center native touchpad pinch both scales and pans the
          // visual viewport, independently of the verified browser zoom.
          await mirror.evaluate('window.scrollTo(137, 211)');
          final viewport = (await mirror.evaluate(
            '({width:visualViewport.width, height:visualViewport.height, '
            'scale:visualViewport.scale})',
          ))! as Map;
          expect(viewport['scale'], closeTo(1, .01));
          // Native pinch is setup only. The asserted clicks below
          // still originate at the independently located Flutter pixels.
          await mirror.command('Input.synthesizePinchGesture', {
            'x': (viewport['width'] as num) * .65,
            'y': (viewport['height'] as num) * .60,
            'scaleFactor': 1.5,
            'gestureSourceType': 'mouse',
          });
          await mirror.waitUntil(() async {
            mirror.viewportEvidence = (await mirror.evaluate(
              '({scale:visualViewport.scale, offsetLeft:visualViewport.offsetLeft, '
              'offsetTop:visualViewport.offsetTop, scrollX, scrollY})',
            ))! as Map;
            return (mirror.viewportEvidence['offsetLeft'] as num).abs() > 2 &&
                (mirror.viewportEvidence['offsetTop'] as num).abs() > 2;
          }, 'Native touchpad pinch did not produce a real visual-viewport pan.');
          expect(mirror.viewportEvidence['scale'], closeTo(1.5, .01));
          await mirror.showNewMarker();
          await mirror.checkPaintedInput('zoom=$zoom pinch=1.5 with nonzero visual offsets');
          await mirror.command('Emulation.setPageScaleFactor', {
            'pageScaleFactor': 1,
          });
          await mirror.evaluate('window.scrollTo(0, 0)');

          // ACKs still go to real Chrome. Only the test transport withholds
          // streaming pictures, forcing the production screenshot fallback.
          mirror.chrome.suppressScreencastFrames = true;
          final screenshots = mirror.chrome.screenshotReplies;
          await mirror.showNewMarker();
          await mirror.waitUntil(
            () => mirror.chrome.screenshotReplies > screenshots,
            'The mirror did not obtain its real fallback screenshot.',
          );
          await mirror.checkPaintedInput('zoom=$zoom screenshot fallback');
          expect(mirror.chrome.suppressedScreencastFrames, greaterThan(0));

          mirror.chrome.suppressScreencastFrames = false;
          final streamed = mirror.chrome.forwardedScreencastFrames;
          await mirror.showNewMarker();
          await mirror.waitUntil(
            () => mirror.chrome.forwardedScreencastFrames > streamed,
            'The real screencast did not resume.',
          );
          await mirror.checkPaintedInput('zoom=$zoom resumed screencast');
          expect(mirror.chrome.errors, isEmpty);
        } finally {
          await mirror.close();
        }
      }, _LoopbackHttpOverrides());
    },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}

class _RealMirror {
  _RealMirror(this.tester, this.bridge);

  final WidgetTester tester;
  final BrowserBridge bridge;
  final control = BrowserAgentControl.instance;
  final oldHome = BrowserBridge.home;
  final oldFolder = BrowserBridge.socketFolder;
  final oldLoopback = BrowserBridge.loopback;
  final oldData = DataDirectory.current;
  final oldLastTab = BrowserTools.lastTab.value;
  final boundaryKey = GlobalKey();
  Directory? _root;
  HttpServer? _server;
  RealChromeFixture? _chrome;
  RealChromeFixture get chrome => _chrome!;
  BrowserConnection? _browser;
  int _marker = 0;
  List<int> _color = const [250, 20, 220];
  Map _expected = const {};
  Map _documentEvidence = const {};
  Map viewportEvidence = const {};

  Finder get pageListener => find.descendant(
    of: find.byType(BrowserMirror),
    matching: find.byWidgetPredicate((widget) => widget is Listener &&
        widget.onPointerHover != null && widget.onPointerPanZoomUpdate != null),
  );

  Future<void> open(double zoom) async {
    // Exercise native Chrome scaling independently from Flutter's view DPR,
    // without increasing the number of real browser test cases.
    final deviceScale = zoom == 2 ? 1.25 : 1.0;
    final executable = Platform.environment['BAOCODE_CHROME_FOR_TESTING'];
    final version = Platform.environment['BAOCODE_CFT_VERSION'];
    expect(executable, isNotNull, reason: 'Supply the official CfT executable.');
    expect(version, matches(RegExp(r'^\d+\.\d+\.\d+\.\d+$')),
        reason: 'Pin and record the official CfT version.');
    expect(bridge.browsers, isEmpty);
    _root = Directory.systemTemp.createTempSync('bao-real-mirror-');
    BrowserBridge.home = p.join(_root!.path, 'empty-home');
    BrowserBridge.socketFolder = _root!.path;
    BrowserBridge.loopback = true;
    DataDirectory.current = DataDirectory(p.join(_root!.path, 'app-data'));
    BrowserTools.lastTab.value = null;
    control.resetForTesting();
    await request<void>(() async {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write(_fixtureHtml);
        await request.response.close();
      });
      final page = Uri.parse('http://127.0.0.1:${_server!.port}/');
      _chrome = RealChromeFixture(_root!, page);
      await bridge.start();
      expect(bridge.otherApp, isFalse);
      await chrome.start(executable!, version!,
          browserZoom: zoom, deviceScaleFactor: deviceScale, initiallyBlank: true);
      await chromeUntil(() => bridge.browsers.length == 1);
      _browser = bridge.browsers.single;
    }, phase: 'start isolated Chrome and native bridge');
    final navigation = await command('Page.navigate', {'url': '${chrome.page}'});
    expect(navigation['errorText'], isNull,
        reason: 'The one explicit localhost navigation failed: $navigation');
    await waitUntil(() async {
      _documentEvidence = (await evaluate(
        '({readyState:document.readyState, origin:location.origin, '
        'path:location.pathname.slice(0,120), title:document.title.slice(0,120), '
        'markerType:typeof window.placeMarker})',
      ))! as Map;
      return _documentEvidence['readyState'] == 'complete' &&
          _documentEvidence['origin'] == chrome.page.origin &&
          _documentEvidence['path'] == chrome.page.path &&
          _documentEvidence['title'] == 'Disposable mirror marker' &&
          _documentEvidence['markerType'] == 'function';
    }, 'The exact isolated marker document did not commit.');
    final metrics = await command('Page.getLayoutMetrics');
    expect((metrics['cssVisualViewport'] as Map)['zoom'], closeTo(zoom, .01),
        reason: 'The disposable profile must apply REAL browser zoom.');
    expect(await evaluate('devicePixelRatio'), closeTo(zoom * deviceScale, .01),
        reason: 'Chrome device scale is $deviceScale, independently of Flutter.');
    final widths = (await evaluate(
      '({inner:innerWidth, visual:visualViewport.width, scale:visualViewport.scale})',
    ))! as Map;
    expect(widths['scale'], closeTo(1, .01));
    expect((widths['inner'] as num) - (widths['visual'] as num), greaterThan(8),
        reason: 'The fixture must reserve a classic scrollbar in its captured surface.');
    expect(control.manualControl, isTrue);
  }

  Future<void> pump(Size panel, double ratio) async {
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = const Size(1120, 760) * ratio;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(size: panel, child: RepaintBoundary(
          key: boundaryKey,
          child: BrowserMirror(
            key: const ValueKey('real-browser-mirror'),
            sessionId: 'disposable-real-browser-mirror',
            initialTab: BrowserTab(_browser!, 1),
          ),
        )),
      )),
    ));
    // Complete the production resize debounce and real socket continuations.
    await tester.pump(const Duration(milliseconds: 220));
    await waitUntil(() => chrome.commands.contains('Page.startScreencast'),
        'The production mirror did not start its real screencast.');
  }

  Future<T> request<T>(Future<T> Function() action, {
    required String phase,
  }) async {
    var completed = false;
    T? result;
    Object? error;
    StackTrace? stack;
    await tester.runAsync(() async {
      unawaited(Future<T>.sync(action).then<void>((value) {
        result = value;
        completed = true;
      }, onError: (Object failure, StackTrace trace) {
        error = failure;
        stack = trace;
        completed = true;
      }));
    });
    final watch = Stopwatch()..start();
    while (!completed && watch.elapsed < const Duration(seconds: 20)) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    final evidence = 'connected=${_browser?.connected}, '
        'last commands=${_chrome?.commands.reversed.take(8).toList()}, '
        'errors=${_chrome?.errors}';
    if (!completed) {
      throw TimeoutException('Real mirror phase "$phase" did not settle. $evidence',
          const Duration(seconds: 20));
    }
    if (error != null) {
      Error.throwWithStackTrace(StateError(
        'Real mirror phase "$phase" failed: $error. $evidence',
      ), stack!);
    }
    return result as T;
  }

  Future<Map<String, Object?>> command(String method,
      [Map<String, Object?> params = const {}]) =>
      request(() => _browser!.cdp(1, method, params), phase: 'CDP $method');

  Future<Object?> evaluate(String expression) async {
    final response = await command('Runtime.evaluate', {
      'expression': expression, 'returnByValue': true, 'awaitPromise': true,
    });
    expect(response['exceptionDetails'], isNull);
    return (response['result'] as Map?)?['value'];
  }

  Future<void> waitUntil(FutureOr<bool> Function() ready, String reason) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 15)) {
      if (await ready()) return;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    fail('$reason Commands: ${chrome.commands.reversed.take(12).toList()}; '
        'errors: ${chrome.errors}; document: $_documentEvidence; '
        'viewport: $viewportEvidence; '
        'input/capture: ${chrome.commandDetails.reversed.take(4).toList()}');
  }

  Future<void> showNewMarker() async {
    _marker++;
    _color = _marker.isOdd ? const [250, 20, 220] : const [20, 230, 250];
    final x = _marker.isOdd ? .73 : .24;
    final y = _marker.isOdd ? .27 : .67;
    _expected = (await evaluate(
      'placeMarker($x, $y, "rgb(${_color.join(',')})")',
    ))! as Map;
    await waitUntil(() async => await paintedMarker() != null,
        'The new colored marker never appeared in the painted mirror.');
  }

  // Read the final Flutter surface, including the toolbar, fit, letterbox,
  // decoded picture and panel position. No production geometry is consulted.
  Future<Rect?> paintedMarker() async {
    final boundary = boundaryKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null || boundary.debugNeedsPaint) return null;
    return request<Rect?>(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (bytes == null) return null;
        var left = image.width;
        var right = -1;
        var top = image.height;
        var bottom = -1;
        var count = 0;
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            final offset = (y * image.width + x) * 4;
            if ((bytes.getUint8(offset) - _color[0]).abs() <= 30 &&
                (bytes.getUint8(offset + 1) - _color[1]).abs() <= 30 &&
                (bytes.getUint8(offset + 2) - _color[2]).abs() <= 30 &&
                bytes.getUint8(offset + 3) > 240) {
              if (x < left) left = x;
              if (x > right) right = x;
              if (y < top) top = y;
              if (y > bottom) bottom = y;
              count++;
            }
          }
        }
        if (count < 30) return null;
        return Rect.fromLTRB(left.toDouble(), top.toDouble(),
            right + 1.0, bottom + 1.0);
      } finally {
        image.dispose();
      }
    }, phase: 'read painted marker image');
  }

  Future<void> checkPaintedInput(String label) async {
    final pixels = (await paintedMarker())!;
    final origin = tester.getTopLeft(find.byKey(boundaryKey));
    final point = origin + pixels.center;
    await evaluate('window.inputEvents = []');
    final gesture = await tester.startGesture(point, kind: PointerDeviceKind.mouse);
    await gesture.up();
    await tester.sendEventToBinding(PointerScrollEvent(
      position: point, scrollDelta: const Offset(0, 12),
    ));
    List events = [];
    await waitUntil(() async {
      events = (await evaluate('window.inputEvents'))! as List;
      return events.any((event) => (event as Map)['type'] == 'wheel') &&
          events.any((event) => (event as Map)['type'] == 'pointerup');
    }, 'Real Chrome did not receive the displayed marker input ($label).');
    for (final type in ['pointerdown', 'pointerup', 'wheel']) {
      final event = events.cast<Map>().singleWhere((event) => event['type'] == type);
      expect(event['trusted'], isTrue, reason: '$label $type must be real input');
      expect(event['target'], 'marker', reason: '$label $type hit another DOM target');
      expect(event['x'], closeTo(_expected['x'] as num, 3), reason: '$label $type clientX');
      expect(event['y'], closeTo(_expected['y'] as num, 3), reason: '$label $type clientY');
    }
    final wheel = events.cast<Map>().singleWhere((event) => event['type'] == 'wheel');
    expect(wheel['deltaMode'], 0);
    expect(wheel['deltaY'], closeTo(12 * (_expected['width'] as num) / pixels.width, 2),
        reason: '$label wheel scale follows actual painted CSS marker width');
    expect(chrome.commandDetails.any((entry) =>
        entry['method'] == 'Input.dispatchMouseEvent'), isTrue);
  }

  Future<void> checkLetterbox(String label) async {
    final page = tester.getRect(pageListener);
    final image = find.descendant(of: find.byType(BrowserMirror),
        matching: find.byType(RawImage));
    expect(image, findsOneWidget);
    final drawn = tester.getRect(image);
    final Offset margin;
    if (drawn.left > page.left + 4) {
      margin = Offset((page.left + drawn.left) / 2, drawn.center.dy);
    } else {
      expect(page.bottom - drawn.bottom, greaterThan(4),
          reason: '$label needs an independently observed blank margin');
      margin = Offset(page.center.dx, (drawn.bottom + page.bottom) / 2);
    }
    await evaluate('window.inputEvents = []');
    final inputs = chrome.commands.where((name) => name == 'Input.dispatchMouseEvent').length;
    await tester.tapAt(margin);
    await tester.sendEventToBinding(PointerScrollEvent(
      position: margin, scrollDelta: const Offset(0, 12),
    ));
    await evaluate('0');
    expect(chrome.commands.where((name) => name == 'Input.dispatchMouseEvent'),
        hasLength(inputs), reason: '$label letterbox sent browser input');
    expect(await evaluate('window.inputEvents'), isEmpty);
  }

  Future<void> close() async {
    try {
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        if (_browser?.connected ?? false) {
          // Advance fake microtasks and real transport together while the
          // disposed mirror's queued stop/ACK requests can still complete.
          await command('Runtime.evaluate', {'expression': '0'});
        }
      } finally {
        try {
          try {
            await request<void>(() async { await _chrome?.drain(); },
                phase: 'drain Chrome commands');
          } finally {
            await request<void>(() async { await _chrome?.close(); },
                phase: 'close isolated Chrome');
          }
        } finally {
          try {
            await request<void>(bridge.stop, phase: 'stop native bridge');
          } finally {
            await request<void>(() async { await _server?.close(force: true); },
                phase: 'close fixture HTTP server');
          }
        }
      }
      expect(_chrome?.errors ?? <String>[], isEmpty,
          reason: 'Late real Chrome/transport errors must fail the smoke.');
    } finally {
      control.resetForTesting();
      BrowserTools.lastTab.value = oldLastTab;
      BrowserBridge.home = oldHome;
      BrowserBridge.socketFolder = oldFolder;
      BrowserBridge.loopback = oldLoopback;
      DataDirectory.current = oldData;
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      await request<void>(() async {
        await chromeUntil(() {
          try {
            if (_root?.existsSync() ?? false) _root!.deleteSync(recursive: true);
            return true;
          } on FileSystemException {
            return false;
          }
        }, reason: 'Disposable mirror profile could not be removed.');
      }, phase: 'remove disposable profile');
      await tester.pump();
    }
  }
}

const _fixtureHtml = '''
<!doctype html><meta charset=utf-8><title>Disposable mirror marker</title>
<style>
html { background: #101010; overflow: scroll; }
::-webkit-scrollbar { width: 18px; height: 18px; }
body { margin: 0; width: 1800px; height: 2400px; }
#marker { position: absolute; width: 96px; height: 64px; border: 0; padding: 0; }
</style><div id=marker></div>
<script>
window.inputEvents = [];
for (const type of ['pointerdown', 'pointerup', 'wheel']) {
  document.addEventListener(type, event => {
    window.inputEvents.push({type, x:event.clientX, y:event.clientY,
      target:event.target.id, trusted:event.isTrusted,
      deltaY:event.deltaY || 0, deltaMode:event.deltaMode || 0});
    // Chrome offers native touchpad pinch as ctrl+wheel before zooming.
    // Allow that setup gesture; keep the measured ordinary wheel stationary.
    if (type === 'wheel' && !event.ctrlKey) event.preventDefault();
  }, {passive:false});
}
window.placeMarker = (x, y, color) => {
  const viewport = window.visualViewport;
  const marker = document.getElementById('marker');
  marker.style.left = (scrollX + viewport.offsetLeft + viewport.width*x - 48) + 'px';
  marker.style.top = (scrollY + viewport.offsetTop + viewport.height*y - 32) + 'px';
  marker.style.background = color;
  const rect = marker.getBoundingClientRect();
  return {x:rect.left+rect.width/2, y:rect.top+rect.height/2, width:rect.width};
};
</script>
''';

// Same isolated real transport as the takeover fixture. No global override,
// proxy routing, DNS names, credentials, external pages, or personal profile.
class _LoopbackHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if ((uri.scheme != 'http' && uri.scheme != 'ws') ||
          uri.host != '127.0.0.1' || uri.port <= 0 || uri.userInfo.isNotEmpty ||
          proxyHost != null || proxyPort != null) {
        throw StateError('Real mirror smoke blocked non-loopback transport.');
      }
      return Socket.startConnect(InternetAddress.loopbackIPv4, uri.port);
    };
    return client;
  }
}
