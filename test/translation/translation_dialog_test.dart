import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:baocode/theme/workbench_theme.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/translation/translation_dialog.dart';
import 'package:baocode/translation/translation_service.dart';

import 'translation_service_test.dart' show configured;

void main() {
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
  for (final brightness in Brightness.values) {
    testWidgets('narrow ${brightness.name} panel scrolls without overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const TranslationDialog(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
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
        }) async => 'A lightweight translator, built into your workspace.',
      );
      final boundaryKey = GlobalKey();
      if (const bool.fromEnvironment('TRANSLATION_PREVIEWS')) {
        await tester.runAsync(() async {
          final font = [
            r'C:\Windows\Fonts\arial.ttf',
            '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
          ].map(File.new).where((f) => f.existsSync()).firstOrNull;
          if (font != null) {
            await (FontLoader('Roboto')..addFont(
                  Future.value(ByteData.sublistView(font.readAsBytesSync())),
                ))
                .load();
          }
        });
      }
      await tester.pumpWidget(
        MaterialApp(
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
      await tester.tap(find.widgetWithText(IdeButton, 'Translate'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
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
