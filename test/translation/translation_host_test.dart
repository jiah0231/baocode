import 'dart:async';

import 'package:baocode/translation/translation_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/translation');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> nativeEvent(String method, [Object? arguments]) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      (_) => done.complete(),
    );
    await done.future;
  }

  test('panel is lazy and never shown before its new frame', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'createPanel' ? 9 : true;
    });
    final host = TranslationHost(
      channel: channel,
      supported: true,
      engineId: 42,
    );
    expect(calls, isEmpty);
    expect(
      await host.openPanel(
        const TranslationCapture(text: 'hello', status: 'ok', requestId: 7),
      ),
      isTrue,
    );
    expect(host.panelViewId, 9);
    expect(calls.map((c) => c.method), ['createPanel']);
    expect(calls.single.arguments, {'engineId': 42});
    await host.panelRendered(host.panelGeneration);
    expect(calls.last.method, 'showPanel');
    expect(calls.last.arguments, {'requestId': 7});
    await host.hidePanel();
    expect(host.panelCapture, isNull);
    expect(host.panelModelSettings, isNull);
  });

  test(
    'replacement invalidates stale frames and native dismiss clears text',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'createPanel' ? 9 : true;
      });
      final host = TranslationHost(
        channel: channel,
        supported: true,
        engineId: 42,
      )..start(null);
      await host.openPanel(const TranslationCapture(text: 'old', requestId: 1));
      final old = host.panelGeneration;
      await host.openPanel(const TranslationCapture(text: 'new', requestId: 2));
      await host.panelRendered(old);
      expect(calls.where((c) => c.method == 'showPanel'), isEmpty);
      await nativeEvent('panelHidden', {'requestId': 1});
      expect(host.panelCapture?.text, 'new');
      await nativeEvent('panelHidden', {'requestId': 2});
      expect(host.panelCapture, isNull);
      await host.panelRendered(host.panelGeneration - 1);
      expect(calls.where((c) => c.method == 'showPanel'), isEmpty);
      host.stop();
    },
  );

  test(
    'closing during creation cannot reopen; later request reuses view',
    () async {
      final created = Completer<int>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'createPanel' ? created.future : true;
      });
      final host = TranslationHost(
        channel: channel,
        supported: true,
        engineId: 42,
      );
      final opening = host.openPanel(const TranslationCapture(text: 'secret'));
      await host.hidePanel();
      created.complete(9);
      expect(await opening, isTrue);
      expect(host.panelCapture, isNull);
      await host.openPanel(const TranslationCapture(text: 'fresh'));
      expect(host.panelCapture?.text, 'fresh');
      expect(calls.where((c) => c.method == 'createPanel'), hasLength(1));
      await host.hidePanel();
    },
  );

  test('creation failure permits fallback, focus rejection does not', () async {
    final host = TranslationHost(
      channel: channel,
      supported: true,
      engineId: 42,
    );
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await host.openPanel(const TranslationCapture()), isFalse);
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'createPanel' ? 9 : false,
    );
    expect(
      await host.openPanel(const TranslationCapture(text: 'discard')),
      isTrue,
    );
    await host.panelRendered(host.panelGeneration);
    expect(host.panelCapture, isNull);
  });

  test(
    'single-view hosts do not create an unrenderable native panel',
    () async {
      final host = TranslationHost(
        channel: channel,
        supported: true,
        panelEnabled: false,
      );
      expect(await host.openPanel(const TranslationCapture()), isFalse);
      expect(calls, isEmpty);
    },
  );

  test('failed or oversized capture cannot carry text', () {
    expect(
      TranslationCapture.fromJson({'status': 'password', 'text': 'secret'})
          .text,
      isEmpty,
    );
    expect(
      TranslationCapture.fromJson({'status': 'unsupported', 'text': 'stale'})
          .text,
      isEmpty,
    );
    expect(
      TranslationCapture.fromJson({'status': 'ok', 'text': 'x' * 8001}).status,
      'tooLong',
    );
    expect(
      TranslationCapture.fromJson({
        'status': 'ok',
        'text': '  chosen  ',
        'self': true,
      }).text,
      '  chosen  ',
    );
    expect(TranslationCapture.fromJson(null).status, 'unsupported');
  });

  test(
    'register pause resume stop never reads clipboard or selection',
    () async {
      final host = TranslationHost(channel: channel, supported: true)
        ..start(null);
      await Future<void>.delayed(Duration.zero);
      expect(host.hotkeyTaken, isTrue);
      await host.pause();
      await host.resume();
      host.stop();
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((call) => call.method), everyElement('setHotkey'));
      expect(calls.map((call) => call.arguments), [
        'ctrl+alt+y',
        '',
        'ctrl+alt+y',
        '',
      ]);
    },
  );

  test('unsupported platform never calls native API', () async {
    final host = TranslationHost(channel: channel, supported: false)
      ..start(null);
    await host.pause();
    await host.resume();
    host.stop();
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
    expect(host.hotkeyTaken, isNull);
  });

  test('conflict is visible and restart can register again', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    final host = TranslationHost(channel: channel, supported: true)
      ..start(null);
    await Future<void>.delayed(Duration.zero);
    expect(host.hotkeyTaken, isFalse);
    host.stop();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(channel, (_) async => true);
    host.start(null);
    await Future<void>.delayed(Duration.zero);
    expect(host.hotkeyTaken, isTrue);
    host.stop();
    await Future<void>.delayed(Duration.zero);
  });
}
