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
