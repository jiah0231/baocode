import 'dart:async';
import 'dart:convert';

import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/translation/translation_confirmation.dart';
import 'package:baocode/translation/translation_dialog.dart';
import 'package:baocode/translation/translation_host.dart';
import 'package:baocode/translation/translation_service.dart';
import 'package:baocode/usage/usage_ledger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'translation_service_test.dart' show configured;

TranslationCapture entry(
  int id, {
  String text = 'Hello world',
  bool review = false,
}) => TranslationCapture(
  text: text,
  status: 'ok',
  requestId: id,
  origin: TranslationOrigin.selectionEntryClick,
  requiresConfirmation: review,
);

Future<void> panel(
  WidgetTester tester,
  TranslationService service,
  TranslationCapture capture, {
  bool active = true,
  Key? key,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: TranslationDialog(
        key: key ?? ValueKey(capture.requestId),
        embedded: true,
        active: active,
        capture: capture,
        service: service,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class Requests {
  final inputs = <String>[];
  final pending = <Completer<String>>[];
  final emitters = <void Function(String)>[];
  int cancelled = 0;
  bool delay = false;
  TranslationService service(ModelProviders providers) => TranslationService(
    providers: providers,
    request:
        (
          system,
          prompt, {
          required model,
          required exact,
          required cancel,
          required onText,
        }) {
          inputs.add((jsonDecode(prompt) as Map)['text'] as String);
          cancel.then((_) => cancelled++);
          emitters.add(onText);
          if (!delay) return Future.value('translated');
          final result = Completer<String>();
          pending.add(result);
          return result.future;
        },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ModelProviders providers;
  late Requests requests;
  late TranslationService service;
  setUp(() async {
    providers = configured();
    await providers.setQuickAskModel('@test/translate');
    requests = Requests();
    service = requests.service(providers);
  });
  tearDown(() => providers.dispose());

  test('only exact native click origin with valid request and successful text qualifies', () {
    for (final origin in [
      null,
      'manual',
      'hotkey',
      'selection',
      'selectionEntry',
      'selectionentryclick',
      true,
    ]) {
      expect(
        TranslationCapture.fromJson({
          'origin': origin,
          'status': 'ok',
          'text': 'hello',
          'requestId': 1,
          'autoTranslate': true,
        }).requestsImmediateTranslation,
        isFalse,
      );
    }
    for (final status in [
      'password',
      'protected',
      'clipboardRestoreFailed',
      'unsupported',
      'tooLong',
      'noSelection',
    ]) {
      final capture = TranslationCapture.fromJson({
        'origin': 'selectionEntryClick',
        'status': status,
        'text': 'private',
        'requestId': 1,
      });
      expect(capture.requestsImmediateTranslation, isFalse);
      expect(capture.text, isEmpty);
    }
    expect(
      TranslationCapture.fromJson({
        'origin': 'selectionEntryClick',
        'status': 'ok',
        'text': 'hello',
      }).requestsImmediateTranslation,
      isFalse,
    );
    expect(entry(1).requestsImmediateTranslation, isTrue);
    expect(entry(1, text: '  ').requestsImmediateTranslation, isFalse);
    expect(entry(1, text: 'x' * 8001).requestsImmediateTranslation, isFalse);
  });

  test(
    'local review rules are conservative examples, not a complete classifier',
    () {
      for (final text in [
        'password=example-secret',
        'My medication is example',
        'SSN: 123-45-6789',
        '护照号：123456789',
        '-----BEGIN PRIVATE KEY-----',
      ]) {
        expect(translationNeedsReview(text), isTrue);
      }
      expect(translationNeedsReview('Hello world'), isFalse);
      // Opaque wording cannot be classified as public or sensitive by these rules.
      expect(translationNeedsReview('The blue folder is mine'), isFalse);
    },
  );

  testWidgets(
    'explicit entry waits for visible panel and submits once to displayed provider',
    (tester) async {
      await panel(tester, service, entry(1), active: false);
      expect(requests.inputs, isEmpty);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              widget.message!.contains('Test provider · translate'),
        ),
        findsOneWidget,
      );
      await panel(tester, service, entry(1));
      expect(requests.inputs, ['Hello world']);
      await panel(tester, service, entry(1));
      await panel(tester, service, entry(1), active: false);
      await panel(tester, service, entry(1));
      expect(requests.inputs, hasLength(1));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              widget.message!.contains('Selecting text alone never sends'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hotkey manual unknown failed and empty captures never auto-send',
    (tester) async {
      var id = 1;
      for (final capture in [
        const TranslationCapture(
          text: 'hello',
          status: 'ok',
          requestId: 1,
          origin: TranslationOrigin.hotkey,
        ),
        const TranslationCapture(text: 'hello', status: 'ok', requestId: 2),
        entry(3, text: ''),
        const TranslationCapture(
          text: 'unsafe',
          status: 'password',
          requestId: 4,
          origin: TranslationOrigin.selectionEntryClick,
        ),
        const TranslationCapture(
          text: 'hello',
          status: 'ok',
          origin: TranslationOrigin.selectionEntryClick,
        ),
      ]) {
        await panel(tester, service, capture, key: ValueKey(id++));
        expect(requests.inputs, isEmpty);
      }
    },
  );

  testWidgets('rebuilding preview cannot upgrade its immutable origin', (
    tester,
  ) async {
    await panel(
      tester,
      service,
      const TranslationCapture(
        text: 'hello',
        status: 'ok',
        requestId: 1,
        origin: TranslationOrigin.hotkey,
      ),
      active: false,
    );
    await panel(tester, service, entry(1));
    expect(requests.inputs, isEmpty);
  });

  testWidgets(
    'sensitive or explicitly uncertain capture requires confirmation of destination',
    (tester) async {
      for (final capture in [
        entry(1, text: 'password=example-secret'),
        entry(2, review: true),
      ]) {
        await panel(tester, service, capture);
        expect(requests.inputs, isEmpty);
        expect(
          find.textContaining('Automatic sending is paused'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Review the text and destination (Test provider · translate)',
          ),
          findsOneWidget,
        );
      }
      final button = find.widgetWithText(IdeButton, 'Translate');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(requests.inputs, ['Hello world']);
    },
  );

  testWidgets(
    'trace mode holds entry in preview and never silently retries after settings change',
    (tester) async {
      final previous = UsageLedger.current;
      final ledger = UsageLedger(MemoryUsageStorage());
      UsageLedger.current = ledger;
      addTearDown(() {
        UsageLedger.current = previous;
        ledger.dispose();
      });
      await ledger.save(UsageLedger.traceKey, true);
      await panel(tester, service, entry(1));
      expect(requests.inputs, isEmpty);
      expect(
        find.textContaining('Automatic translation is paused'),
        findsOneWidget,
      );
      await ledger.save(UsageLedger.traceKey, false);
      await tester.pumpAndSettle();
      expect(requests.inputs, isEmpty);
    },
  );

  testWidgets(
    'missing provider stays preview even if configuration appears later',
    (tester) async {
      final previous = ClaudeCore.current;
      ClaudeCore.current = () => ClaudeCore.builtin;
      addTearDown(() => ClaudeCore.current = previous);
      final empty = ModelProviders.memory();
      addTearDown(empty.dispose);
      await panel(tester, requests.service(empty), entry(1));
      expect(requests.inputs, isEmpty);
      expect(
        find.textContaining('Configure an available Quick Ask model'),
        findsOneWidget,
      );
      await empty.save(providers.provider('test')!);
      await empty.setQuickAskModel('@test/translate');
      await tester.pumpAndSettle();
      expect(requests.inputs, isEmpty);
    },
  );

  testWidgets(
    'cancelled entry is never restarted by rebuild or visibility changes',
    (tester) async {
      requests.delay = true;
      await panel(tester, service, entry(1));
      final cancel = find.widgetWithText(IdeButton, 'Cancel');
      await tester.ensureVisible(cancel);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(requests.cancelled, 1);
      requests.pending.single.complete('cancelled result');
      await tester.pumpAndSettle();
      await panel(tester, service, entry(1), active: false);
      await panel(tester, service, entry(1));
      expect(requests.inputs, hasLength(1));
      expect(find.text('cancelled result'), findsNothing);
    },
  );

  testWidgets('editing the hidden preview does not authorize automatic send', (
    tester,
  ) async {
    await panel(tester, service, entry(1), active: false);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('translation-source')),
        matching: find.byType(EditableText),
      ),
      'edited source',
    );
    await panel(tester, service, entry(1));
    expect(requests.inputs, isEmpty);
  });

  testWidgets(
    'replacement and close cancel the old click and reject late text',
    (tester) async {
      requests.delay = true;
      await panel(tester, service, entry(1, text: 'first selection'));
      expect(requests.inputs, ['first selection']);
      await panel(tester, service, entry(2, text: 'new selection'));
      expect(requests.inputs, ['first selection', 'new selection']);
      expect(requests.cancelled, 1);
      requests.emitters.first('stale output');
      requests.pending.first.complete('stale result');
      await tester.pumpAndSettle();
      expect(find.text('stale output'), findsNothing);
      expect(find.text('stale result'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(requests.cancelled, 2);
      requests.pending.last.complete('late result');
      await tester.pumpAndSettle();
      expect(find.text('late result'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'native duplicate and stale request identities cannot recreate a session',
    () async {
      const channel = MethodChannel('test/translation-origin');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'createPanel' ? 9 : true,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final host = TranslationHost(
        channel: channel,
        supported: true,
        engineId: 42,
      );
      await host.openPanel(entry(42));
      final generation = host.panelGeneration;
      await host.openPanel(entry(42, text: 'duplicate delivery'));
      await host.openPanel(entry(41, text: 'late old click'));
      expect(host.panelGeneration, generation);
      expect(host.panelCapture?.text, 'Hello world');
      await host.hidePanel();
      await host.openPanel(entry(42));
      expect(host.panelCapture, isNull);
      await host.openPanel(entry(43, text: 'new gesture'));
      expect(host.panelCapture?.text, 'new gesture');
      await host.hidePanel();
    },
  );
}
