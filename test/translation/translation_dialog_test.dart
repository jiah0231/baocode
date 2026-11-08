import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:baocode/theme/workbench_theme.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/translation/translation_dialog.dart';
import 'package:baocode/translation/translation_service.dart';
import 'package:baocode/usage/usage_ledger.dart';

import 'translation_service_test.dart' show configured;

void main() {
  testWidgets('warns live when optional usage debug tracing is enabled', (
    tester,
  ) async {
    final previous = UsageLedger.current;
    final ledger = UsageLedger(MemoryUsageStorage());
    UsageLedger.current = ledger;
    addTearDown(() {
      UsageLedger.current = previous;
      ledger.dispose();
    });
    await tester.pumpWidget(
      const MaterialApp(home: TranslationDialog(selectedText: 'hello')),
    );
    final warning = find.textContaining('Usage debug tracing is on');
    expect(warning, findsNothing);
    await ledger.save(UsageLedger.traceKey, true);
    await tester.pumpAndSettle();
    expect(warning, findsOneWidget);
    await ledger.save(UsageLedger.enabledKey, false);
    await tester.pumpAndSettle();
    expect(warning, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'opening and changing language never sends; explicit translate does',
    (tester) async {
      final providers = configured();
      addTearDown(providers.dispose);
      await providers.setQuickAskModel('@test/translate');
      var calls = 0;
      final service = TranslationService(
        providers: providers,
        request:
            (
              s,
              p, {
              required model,
              required exact,
              required cancel,
              required onText,
            }) async {
              calls++;
              return '你好';
            },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationDialog(selectedText: 'hello', service: service),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.tap(find.text('中文'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('日本語'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.tap(find.widgetWithText(IdeButton, 'Translate'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('你好'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('cancel invalidates pending translation, escape closes', (
    tester,
  ) async {
    final providers = configured();
    addTearDown(providers.dispose);
    await providers.setQuickAskModel('@test/translate');
    final pending = Completer<String>();
    var closed = false;
    final service = TranslationService(
      providers: providers,
      request: (
        s,
        p, {
        required model,
        required exact,
        required cancel,
        required onText,
      }) => pending.future,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TranslationDialog(
          selectedText: 'hello',
          service: service,
          onClose: () => closed = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(IdeButton, 'Translate'));
    await tester.pump();
    await tester.tap(find.widgetWithText(IdeButton, 'Cancel'));
    await tester.pump();
    pending.complete('late');
    await tester.pumpAndSettle();
    expect(find.text('late'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, isTrue);
  });
  testWidgets('truncated capture is not silently submitted', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TranslationDialog(
          selectedText: 'clipped',
          captureStatus: 'tooLong',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('clipped'), findsNothing);
    expect(find.textContaining('Source exceeds'), findsOneWidget);
    expect(
      tester
          .widget<IdeButton>(find.widgetWithText(IdeButton, 'Translate'))
          .onPressed,
      isNull,
    );
  });
  for (final theme in ['Bao Dark', 'Bao Light']) {
    testWidgets('narrow $theme footer is reachable and usable', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous = WorkbenchThemeService.instance;
      final themes = WorkbenchThemeService()..restore(setting: theme);
      WorkbenchThemeService.instance = themes;
      addTearDown(() {
        WorkbenchThemeService.instance = previous;
        themes.dispose();
      });
      final providers = configured();
      addTearDown(providers.dispose);
      await providers.setQuickAskModel('@test/translate');
      var calls = 0;
      final service = TranslationService(
        providers: providers,
        request:
            (
              s,
              p, {
              required model,
              required exact,
              required cancel,
              required onText,
            }) async {
              calls++;
              return 'Translated text';
            },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationDialog(selectedText: 'hello', service: service),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final translate = find.widgetWithText(IdeButton, 'Translate');
      await tester.ensureVisible(translate);
      await tester.pumpAndSettle();
      expect(translate.hitTestable(), findsOneWidget);
      await tester.tap(translate);
      await tester.pumpAndSettle();
      expect(calls, 1);
      final copy = find.widgetWithText(IdeButton, 'Copy translation');
      await tester.ensureVisible(copy);
      await tester.pumpAndSettle();
      expect(copy.hitTestable(), findsOneWidget);
      expect(tester.widget<IdeButton>(copy).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  for (final failCopy in [false, true]) {
    testWidgets(
      'explicit copy ${failCopy ? 'failure' : 'success'} uses only completed translation',
      (tester) async {
        final providers = configured();
        addTearDown(providers.dispose);
        await providers.setQuickAskModel('@test/translate');
        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
              if (failCopy) {
                throw PlatformException(
                  code: 'clipboard-denied',
                  message: 'private platform details',
                );
              }
            }
            if (call.method == 'Clipboard.hasStrings') return {'value': false};
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final service = TranslationService(
          providers: providers,
          request: (
            s,
            p, {
            required model,
            required exact,
            required cancel,
            required onText,
          }) async => 'Translated result',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: TranslationDialog(
              selectedText: 'Original text',
              service: service,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IdeButton>(
                find.widgetWithText(IdeButton, 'Copy translation'),
              )
              .onPressed,
          isNull,
        );
        expect(copied, isEmpty);
        await tester.tap(find.widgetWithText(IdeButton, 'Translate'));
        await tester.pumpAndSettle();
        expect(copied, isEmpty);
        final copy = find.widgetWithText(IdeButton, 'Copy translation');
        await tester.ensureVisible(copy);
        await tester.tap(copy);
        await tester.pumpAndSettle();
        expect(copied, ['Translated result']);
        expect(find.text('private platform details'), findsNothing);
        if (failCopy) {
          expect(
            find.text(
              'Could not copy. Select the translation to copy manually.',
            ),
            findsOneWidget,
          );
          expect(find.widgetWithText(IdeButton, 'Copied'), findsNothing);
        } else {
          expect(find.widgetWithText(IdeButton, 'Copied'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'editing source cancels stream and requires an explicit new translation',
    (tester) async {
      final providers = configured();
      addTearDown(providers.dispose);
      await providers.setQuickAskModel('@test/translate');
      final pending = Completer<String>();
      late void Function(String) emit;
      var cancelled = false;
      final inputs = <String>[];
      final service = TranslationService(
        providers: providers,
        request:
            (
              s,
              p, {
              required model,
              required exact,
              required cancel,
              required onText,
            }) {
              inputs.add((jsonDecode(p) as Map)['text'] as String);
              if (inputs.length > 1) return Future.value('New translation');
              emit = onText;
              cancel.then((_) => cancelled = true);
              return pending.future;
            },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationDialog(
            selectedText: 'Original text',
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(IdeButton, 'Translate'));
      await tester.pump();
      emit('Partial old translation');
      await tester.pump();
      expect(find.text('Partial old translation'), findsOneWidget);
      final input = find.descendant(
        of: find.byKey(const ValueKey('translation-source')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(input, 'Edited text');
      await tester.pump();
      expect(cancelled, isTrue);
      expect(inputs, ['Original text']);
      expect(find.text('Partial old translation'), findsNothing);
      emit('Late old translation');
      pending.complete('Late completed translation');
      await tester.pumpAndSettle();
      expect(find.text('Late old translation'), findsNothing);
      expect(find.text('Late completed translation'), findsNothing);
      await tester.tap(find.widgetWithText(IdeButton, 'Translate'));
      await tester.pumpAndSettle();
      expect(inputs, ['Original text', 'Edited text']);
      expect(find.text('New translation'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'model settings action closes panel and invokes requested callback',
    (tester) async {
      late BuildContext host;
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              host = context;
              return const SizedBox();
            },
          ),
        ),
      );
      unawaited(showTranslationDialog(host, onModelSettings: () => calls++));
      await tester.pumpAndSettle();
      final settings = find.widgetWithText(IdeButton, 'Model settings');
      await tester.ensureVisible(settings);
      await tester.tap(settings);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byType(TranslationDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sanitized provider failure can be retried explicitly', (
    tester,
  ) async {
    final providers = configured();
    addTearDown(providers.dispose);
    await providers.setQuickAskModel('@test/translate');
    var calls = 0;
    final service = TranslationService(
      providers: providers,
      request:
          (
            s,
            p, {
            required model,
            required exact,
            required cancel,
            required onText,
          }) async {
            calls++;
            if (calls == 1) throw StateError('private-api-key');
            return 'Retry succeeded';
          },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TranslationDialog(selectedText: 'hello', service: service),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(IdeButton, 'Translate'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.textContaining('private-api-key'), findsNothing);
    expect(
      find.text('Translation failed. Check the model connection and retry.'),
      findsOneWidget,
    );
    final retry = find.widgetWithText(IdeButton, 'Retry');
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Retry succeeded'), findsOneWidget);
    expect(
      find.text('Translation failed. Check the model connection and retry.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'repeated opening keeps one panel and reopening works after close',
    (tester) async {
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              host = context;
              return const SizedBox();
            },
          ),
        ),
      );
      unawaited(
        showTranslationDialog(host, selectedText: 'hello', captureStatus: 'ok'),
      );
      await tester.pumpAndSettle();
      await showTranslationDialog(host, selectedText: 'duplicate');
      await tester.pumpAndSettle();
      expect(find.byType(TranslationDialog), findsOneWidget);
      expect(
        find.textContaining('No selected text was captured'),
        findsNothing,
      );
      await tester.tap(find.widgetWithText(IdeButton, 'Close'));
      await tester.pumpAndSettle();
      unawaited(showTranslationDialog(host));
      await tester.pumpAndSettle();
      expect(find.byType(TranslationDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(IdeButton, 'Close'));
      await tester.pumpAndSettle();
    },
  );
  for (final theme in ['Bao Dark', 'Bao Light']) {
    testWidgets('renders $theme translation preview', (tester) async {
      final previous = WorkbenchThemeService.instance;
      final themes = WorkbenchThemeService()..restore(setting: theme);
      WorkbenchThemeService.instance = themes;
      addTearDown(() {
        WorkbenchThemeService.instance = previous;
        themes.dispose();
      });
      final providers = configured();
      addTearDown(providers.dispose);
      await providers.setQuickAskModel('@test/translate');
      final service = TranslationService(
        providers: providers,
        request: (
          s,
          p, {
          required model,
          required exact,
          required cancel,
          required onText,
        }) async => '轻巧的翻译工具，融入你的工作空间。',
      );
      final boundaryKey = GlobalKey();
      if (const bool.fromEnvironment('TRANSLATION_PREVIEWS')) {
        await tester.runAsync(() async {
          final font = File(
            'assets/fonts/maple/MapleMonoNormal-NF-CN-Regular.ttf',
          );
          if (font.existsSync()) {
            await (FontLoader('TranslationPreview')..addFont(
                  Future.value(ByteData.sublistView(font.readAsBytesSync())),
                ))
                .load();
          }
        });
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'TranslationPreview'),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RepaintBoundary(
            key: boundaryKey,
            child: TranslationDialog(
              service: service,
              selectedText:
                  'A lightweight translator, built into your workspace.',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(IdeButton, '翻译'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        DefaultTextStyle.of(tester.element(find.text('原文'))).style.fontFamily,
        'TranslationPreview',
      );
      if (const bool.fromEnvironment('TRANSLATION_PREVIEWS')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('build/translation-previews/$theme.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
    });
  }
}
