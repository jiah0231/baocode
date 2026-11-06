import 'dart:async';
import 'dart:convert';

import 'package:baocode/ide/document/faithful_office_preview.dart';
import 'package:baocode/ide/ide_hover.dart';
import 'package:baocode/platform/native_overlay_occlusion.dart';
import 'package:baocode/theme/workbench_theme.dart' hide ColorScheme;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../document_fixtures.dart';

const _channel = MethodChannel('baocode/document_preview');
const _timeout = Timeout(Duration(minutes: 2));

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  final elapsed = Stopwatch()..start();
  while (!ready() && elapsed.elapsed < const Duration(seconds: 15)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  }
  expect(ready(), isTrue, reason: 'Native host handshake did not complete.');
}

class _Host {
  _Host(this.tester, {this.openError}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'open' && openError != null) throw openError!;
      return null;
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        null,
      );
    });
  }

  final WidgetTester tester;
  final Object? openError;
  final calls = <MethodCall>[];

  List<Map<dynamic, dynamic>> of(String method) => [
    for (final call in calls)
      if (call.method == method) call.arguments as Map<dynamic, dynamic>,
  ];

  List<Map<String, dynamic>> get messages => [
    for (final args in of('postMessage'))
      jsonDecode(args['json'] as String) as Map<String, dynamic>,
  ];

  Future<void> event(int id, String type) async {
    tester.binding.channelBuffers.push(
      _channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('event', {'id': id, 'type': type}),
      ),
      (_) {},
    );
    await tester.pump();
  }

  Future<int> opened([int count = 1]) async {
    await _wait(tester, () => of('open').length >= count);
    return of('open')[count - 1]['id'] as int;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required Future<Uint8List> Function(String) read,
  String path = '/workspace/layout.docx',
  int revision = 0,
  bool historical = false,
  Widget? overlay,
  VoidCallback? onOpenInDefaultApp,
}) => tester.pumpWidget(
  WorkbenchThemeScope(
    builder: (_) => MaterialApp(
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            FaithfulOfficePreview(
              path: path,
              read: read,
              revision: revision,
              historical: historical,
              onOpenInDefaultApp: onOpenInDefaultApp,
            ),
            if (overlay != null)
              Positioned(
                left: 20,
                top: 80,
                width: 10,
                height: 10,
                child: overlay,
              ),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'compact actions share the loaded viewer without a separate toolbar row',
    (tester) async {
      final host = _Host(tester);
      var reads = 0;
      var externalOpens = 0;
      await _pump(
        tester,
        path: '/workspace/layout.pdf',
        read: (_) async {
          reads++;
          return Uint8List.fromList(ascii.encode('%PDF-1.7\n'));
        },
        onOpenInDefaultApp: () => externalOpens++,
      );
      Finder action(String tooltip) => find.byWidgetPredicate(
        (widget) => widget is IdeActionButton && widget.tooltip == tooltip,
      );
      expect(find.text('Reload'), findsNothing);
      expect(find.text('Open in default app'), findsNothing);
      expect(tester.getSize(action('Reload')), const Size(24, 24));
      expect(tester.getSize(action('Open in default app')), const Size(24, 24));
      await tester.tap(action('Open in default app'));
      expect(externalOpens, 1);
      final first = await host.opened();
      final bounds = host.of('open').single;
      expect(bounds['format'], 'pdf');
      expect(bounds['y'], 28.0 * tester.view.devicePixelRatio);
      await host.event(first, 'openExternal');
      await host.event(first, 'reload');
      expect(externalOpens, 1, reason: 'Unloaded hosts cannot request actions.');
      expect(reads, 1);
      await host.event(first, 'ready');
      expect(host.messages.first['theme']['canOpenExternal'], isTrue);
      await host.event(first, 'loaded');
      expect(find.byType(IdeActionButton), findsNothing);
      await _wait(
        tester,
        () => host.of('updateBounds').any((bounds) => bounds['y'] == 0.0),
      );
      final loadedBounds = host.of('updateBounds').last;
      expect(loadedBounds['height'], tester.view.physicalSize.height);
      await host.event(first, 'openExternal');
      expect(externalOpens, 2);
      await host.event(first, 'reload');
      final second = await host.opened(2);
      expect(second, isNot(first));
      expect(reads, 2);
      expect(host.of('dispose').map((a) => a['id']), contains(first));
      await host.event(first, 'reload');
      await host.event(first, 'openExternal');
      expect(reads, 2, reason: 'Repeated events from a disposed host are ignored.');
      expect(externalOpens, 2);
      await host.event(second, 'ready');
      await host.event(second, 'loaded');
      expect(find.byType(IdeActionButton), findsNothing);
    },
    timeout: _timeout,
  );

  testWidgets(
    'IgnorePointer overlays hide and restore the existing native host',
    (tester) async {
      final host = _Host(tester);
      var reads = 0;
      Future<Uint8List> read(String _) async {
        reads++;
        return wordDocument();
      }

      await _pump(tester, read: read);
      final id = await host.opened();
      final viewId = host.of('open').single['viewId'] as int;
      await host.event(id, 'ready');
      await host.event(id, 'loaded');
      bool visible(bool expected) =>
          host.of('updateBounds').isNotEmpty &&
          host.of('updateBounds').last['visible'] == expected;
      await _wait(tester, () => visible(true));
      expect(NativeOverlayOcclusion.coversView(viewId), isFalse);

      await _pump(
        tester,
        read: read,
        overlay: const NativeOverlayOcclusion(
          child: IgnorePointer(child: ColoredBox(color: Colors.amber)),
        ),
      );
      await _wait(tester, () => visible(false));
      expect(NativeOverlayOcclusion.coversView(viewId), isTrue);
      expect(host.of('open'), hasLength(1));
      expect(reads, 1);

      await _pump(tester, read: read);
      await _wait(tester, () => visible(true));
      expect(NativeOverlayOcclusion.coversView(viewId), isFalse);
      expect(host.of('open'), hasLength(1));
      expect(host.messages.where((m) => m['type'] == 'load'), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(NativeOverlayOcclusion.coversView(viewId), isFalse);
      expect(host.of('dispose').map((a) => a['id']), contains(id));
    },
    timeout: _timeout,
  );

  testWidgets(
    'overlay marker remains until the last marker in its view disposes',
    (tester) async {
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      final viewId = tester.view.viewId;
      Widget markers({required bool first, required bool second}) =>
          Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [
                if (first)
                  const NativeOverlayOcclusion(
                    key: ValueKey('first'),
                    child: SizedBox(width: 10, height: 10),
                  ),
                if (second)
                  const NativeOverlayOcclusion(
                    key: ValueKey('second'),
                    child: IgnorePointer(
                      child: SizedBox(width: 10, height: 10),
                    ),
                  ),
              ],
            ),
          );
      expect(NativeOverlayOcclusion.coversView(viewId), isFalse);
      await tester.pumpWidget(markers(first: true, second: true));
      expect(NativeOverlayOcclusion.coversView(viewId), isTrue);
      expect(NativeOverlayOcclusion.coversView(viewId + 10000), isFalse);
      await tester.pumpWidget(markers(first: false, second: true));
      expect(NativeOverlayOcclusion.coversView(viewId), isTrue);
      await tester.pumpWidget(markers(first: false, second: false));
      expect(NativeOverlayOcclusion.coversView(viewId), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(NativeOverlayOcclusion.coversView(viewId), isFalse);
    },
    timeout: _timeout,
  );

  testWidgets('host receives original bytes and only the fixed load bridge', (
    tester,
  ) async {
    final host = _Host(tester);
    final bytes = wordImageDocument();
    final original = Uint8List.fromList(bytes);
    await _pump(tester, read: (_) async => bytes);
    final id = await host.opened();
    final open = host.of('open').single;
    expect(open['bytes'], orderedEquals(original));
    expect(bytes, orderedEquals(original));
    expect(open['format'], 'docx');
    expect(open['viewId'], isA<int>());
    expect(open['width'] as double, greaterThan(0));
    expect(open['height'] as double, greaterThan(0));
    expect(open['visible'], isFalse);
    expect(host.messages, isEmpty);
    await host.event(id, 'ready');
    expect(host.messages.map((message) => message['type']), ['theme', 'load']);
    expect(host.messages.last, {
      'type': 'load',
      'kind': 'docx',
      'name': 'layout.docx',
      'url': '/document',
    });
    await host.event(id, 'ready');
    expect(host.messages.where((m) => m['type'] == 'load'), hasLength(1));
    await host.event(id, 'loaded');
    expect(host.messages.first['theme']['canOpenExternal'], isFalse);
    await host.event(id, 'openExternal');
    expect(
      host.calls.map((c) => c.method),
      isNot(contains('evaluateJavaScript')),
    );
  }, timeout: _timeout);

  testWidgets('native reload does not retain a previous preview test zone', (
    tester,
  ) async {
    final host = _Host(tester);
    var reads = 0;
    await _pump(
      tester,
      read: (_) async {
        reads++;
        return slideDocument();
      },
      path: '/workspace/layout.pptx',
    );
    final id = await host.opened();
    expect(reads, 1);
    expect(host.of('open').single['format'], 'pptx');
    await host.event(id, 'ready');
    await host.event(id, 'loaded');
    await host.event(id, 'reload');
    final reloaded = await host.opened(2);
    expect(reloaded, isNot(id));
    expect(reads, 2);
    expect(host.of('dispose').map((args) => args['id']), contains(id));
    await host.event(reloaded, 'ready');
    await host.event(reloaded, 'loaded');
  }, timeout: _timeout);

  testWidgets('switching files ignores the cancelled read and stale events', (
    tester,
  ) async {
    final host = _Host(tester);
    final slow = Completer<Uint8List>();
    final calls = <String>[];
    Future<Uint8List> read(String path) {
      calls.add(path);
      return path.endsWith('old.docx')
          ? slow.future
          : Future.value(spreadsheetDocument());
    }

    await _pump(tester, read: read, path: '/workspace/old.docx');
    await _wait(tester, () => calls.isNotEmpty);
    await _pump(tester, read: read, path: '/workspace/new.xlsx');
    // Complete the obsolete transport; no bytes from it may reach the host.
    slow.complete(wordDocument());
    final id = await host.opened();
    expect(host.of('open'), hasLength(1));
    expect(host.of('open').single['format'], 'xlsx');
    await host.event(id + 10000, 'ready');
    expect(host.messages, isEmpty);
    await host.event(id, 'ready');
    await host.event(id, 'loaded');
    expect(host.messages.last['kind'], 'xlsx');
  }, timeout: _timeout);

  testWidgets(
    'revision and reload dispose old hosts before opening a new one',
    (tester) async {
      final host = _Host(tester);
      var reads = 0;
      Future<Uint8List> read(String _) async {
        reads++;
        return wordDocument();
      }

      await _pump(tester, read: read);
      final first = await host.opened();
      await host.event(first, 'ready');
      await host.event(first, 'loaded');
      await _pump(tester, read: read, revision: 1);
      final second = await host.opened(2);
      expect(second, isNot(first));
      expect(host.of('dispose').map((a) => a['id']), contains(first));
      final messages = host.messages.length;
      await host.event(first, 'ready');
      expect(host.messages, hasLength(messages));
      await host.event(second, 'ready');
      await host.event(second, 'loaded');
      await host.event(second, 'reload');
      final third = await host.opened(3);
      expect(reads, 3);
      expect(host.of('dispose').map((a) => a['id']), contains(second));
      await host.event(third, 'ready');
      await host.event(third, 'loaded');
    },
    timeout: _timeout,
  );

  testWidgets('disposing an unfinished read never opens a native surface', (
    tester,
  ) async {
    final host = _Host(tester);
    final slow = Completer<Uint8List>();
    var started = false;
    await _pump(
      tester,
      read: (_) {
        started = true;
        return slow.future;
      },
    );
    await _wait(tester, () => started);
    await tester.pumpWidget(const SizedBox.shrink());
    slow.complete(wordDocument());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
    expect(host.of('open'), isEmpty);
    expect(tester.takeException(), isNull);
  }, timeout: _timeout);

  testWidgets(
    'missing runtime reports a retryable error without external open',
    (tester) async {
      final host = _Host(
        tester,
        openError: MissingPluginException('Unavailable'),
      );
      await _pump(tester, read: (_) async => wordDocument());
      final id = await host.opened();
      await _wait(tester, () => find.text('Try again').evaluate().isNotEmpty);
      expect(host.of('dispose').map((a) => a['id']), contains(id));
      expect(host.messages, isEmpty);
      expect(host.calls.map((c) => c.method), isNot(contains('openExternal')));
    },
    timeout: _timeout,
  );

  testWidgets('historical documents never read the current working file', (
    tester,
  ) async {
    final host = _Host(tester);
    var reads = 0;
    await _pump(
      tester,
      historical: true,
      read: (_) async {
        reads++;
        return wordDocument();
      },
    );
    await tester.pump();
    expect(reads, 0);
    expect(host.of('open'), isEmpty);
  }, timeout: _timeout);

  testWidgets(
    'theme updates send colors without rereading or reloading bytes',
    (tester) async {
      final saved = WorkbenchThemeService.instance;
      addTearDown(() => WorkbenchThemeService.instance = saved);
      WorkbenchThemeService.instance = WorkbenchThemeService()
        ..restore(setting: 'Bao Light');
      final host = _Host(tester);
      var reads = 0;
      Future<Uint8List> read(String _) async {
        reads++;
        return wordDocument();
      }

      await _pump(tester, read: read);
      final id = await host.opened();
      await host.event(id, 'ready');
      await host.event(id, 'loaded');
      final firstTheme = host.messages.firstWhere((m) => m['type'] == 'theme');
      WorkbenchThemeService.instance = WorkbenchThemeService()
        ..restore(setting: 'Bao Dark');
      await _pump(tester, read: read);
      await tester.pump();
      final themes = host.messages.where((m) => m['type'] == 'theme').toList();
      expect(themes.length, greaterThanOrEqualTo(2));
      expect(themes.last['theme'], isNot(firstTheme['theme']));
      expect(reads, 1);
      expect(host.of('open'), hasLength(1));
      expect(host.messages.where((m) => m['type'] == 'load'), hasLength(1));
    },
    timeout: _timeout,
  );
}
