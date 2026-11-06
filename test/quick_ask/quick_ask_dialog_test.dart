import 'dart:async';
import 'dart:convert';

import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/quick_ask/quick_ask_context.dart';
import 'package:baocode/quick_ask/quick_ask_dialog.dart';
import 'package:baocode/quick_ask/quick_ask_service.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:flutter/material.dart' hide ColorScheme;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Request {
  int calls = 0;
  Map<String, dynamic>? input;
  Completer<String>? pending;
  Future<void>? cancelled;
  Object? error;

  Future<String> call(
    String system,
    String prompt, {
    String? model,
    required bool exact,
    Future<void>? cancel,
  }) async {
    calls++;
    input = jsonDecode(prompt) as Map<String, dynamic>;
    cancelled = cancel;
    if (error case final error?) throw error;
    return pending?.future ?? 'replacement';
  }
}

void main() {
  late _Request request;
  late QuickAskService service;
  late ModelProviders providers;

  setUp(() {
    final previous = ModelProviders.current;
    providers = ModelProviders.memory(
      providers: const [
        ModelProvider(
          id: 'test',
          name: 'Test',
          baseUrl: 'https://model.example.com',
          models: [ProviderModel(id: 'small')],
        ),
      ],
    );
    ModelProviders.current = providers;
    addTearDown(() {
      ModelProviders.current = previous;
      providers.dispose();
    });
    request = _Request();
    service = QuickAskService(request: request.call, providers: providers);
  });

  Future<void> open(
    WidgetTester tester, {
    QuickAskContext? source,
    Locale? locale,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Center(
            child: IdeButton(
              label: 'open',
              onPressed: () => unawaited(
                showQuickAsk(context, source: source, service: service),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder question() => find.descendant(
    of: find.byKey(const ValueKey('quick-ask-question')),
    matching: find.byType(EditableText),
  );

  Future<void> send(WidgetTester tester) async {
    await tester.enterText(question(), 'Explain this');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'opens without a request, reviews bounded context, can omit surroundings',
    (tester) async {
      await open(
        tester,
        source: const QuickAskContext(
          sourceLabel: 'lib/example.dart',
          selectedText: 'selected',
          contextText: 'nearby',
        ),
      );
      expect(request.calls, 0);
      await tester.tap(find.text('Review context'));
      await tester.pumpAndSettle();
      expect(find.text('selected'), findsOneWidget);
      expect(find.text('nearby'), findsOneWidget);
      await tester.tap(find.text('Nearby context: on'));
      await tester.pumpAndSettle();
      expect(find.text('nearby'), findsNothing);
      await send(tester);
      expect(request.calls, 1);
      expect(request.input!['selection'], 'selected');
      expect(request.input!['context'], '');
      expect(find.text('replacement'), findsOneWidget);
      expect(find.text('Apply replacement'), findsNothing);
    },
  );

  testWidgets('edit is previewed and editable before one explicit apply', (
    tester,
  ) async {
    final applied = <String>[];
    await open(
      tester,
      source: QuickAskContext(
        sourceLabel: 'file.dart',
        selectedText: 'original',
        applyReplacement: (text) {
          applied.add(text);
          return true;
        },
      ),
    );
    await tester.tap(find.text('Edit selection'));
    await send(tester);
    expect(request.input!['mode'], 'edit');
    expect(applied, isEmpty);
    expect(find.text('original'), findsOneWidget);
    final replacement = find.descendant(
      of: find.byKey(const ValueKey('quick-ask-replacement')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(replacement, 'reviewed replacement');
    await tester.ensureVisible(find.text('Apply replacement'));
    await tester.tap(find.text('Apply replacement'));
    await tester.pumpAndSettle();
    expect(applied, ['reviewed replacement']);
    await tester.tap(find.text('Applied'));
    await tester.pumpAndSettle();
    expect(applied, hasLength(1));
  });

  testWidgets(
    'stale source preserves proposal and reports failed application',
    (tester) async {
      await open(
        tester,
        source: QuickAskContext(
          sourceLabel: 'file.dart',
          selectedText: 'original',
          applyReplacement: (_) => false,
        ),
      );
      await tester.tap(find.text('Edit selection'));
      await send(tester);
      await tester.ensureVisible(find.text('Apply replacement'));
      await tester.tap(find.text('Apply replacement'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The source changed or closed.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('quick-ask-replacement')),
        findsOneWidget,
      );
      expect(find.text('Applied'), findsNothing);
    },
  );

  testWidgets(
    'chat selections support replacement copy without rewriting history',
    (tester) async {
      await open(
        tester,
        source: const QuickAskContext(
          sourceLabel: 'Agent',
          selectedText: 'a message',
        ),
      );
      await tester.tap(find.text('Edit selection'));
      await send(tester);
      expect(
        find.byKey(const ValueKey('quick-ask-replacement')),
        findsOneWidget,
      );
      expect(find.text('Apply replacement'), findsNothing);
      expect(find.textContaining('This source is read-only'), findsOneWidget);
    },
  );

  testWidgets('no selection and clipped selections cannot request an edit', (
    tester,
  ) async {
    await open(
      tester,
      source: const QuickAskContext(
        sourceLabel: 'large',
        selectedText: 'clipped',
        truncated: true,
      ),
    );
    final edit = tester.widget<IdeButton>(
      find.ancestor(
        of: find.text('Edit selection'),
        matching: find.byType(IdeButton),
      ),
    );
    expect(edit.onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await open(tester);
    final noSelection = tester.widget<IdeButton>(
      find.ancestor(
        of: find.text('Edit selection'),
        matching: find.byType(IdeButton),
      ),
    );
    expect(noSelection.onPressed, isNull);
  });

  testWidgets('stop discards a late answer and permits a fresh request', (
    tester,
  ) async {
    request.pending = Completer<String>();
    await open(tester);
    await tester.enterText(question(), 'Explain');
    await tester.tap(find.text('Send'));
    await tester.pump();
    await tester.pump();
    expect(request.calls, 1);
    var cancelled = false;
    unawaited(request.cancelled!.then((_) => cancelled = true));
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
    request.pending!.complete('late result');
    request.pending = null;
    await tester.pumpAndSettle();
    expect(find.text('late result'), findsNothing);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(request.calls, 2);
    expect(find.text('replacement'), findsOneWidget);
  });

  testWidgets('Escape cancels and reopening has no old result or draft', (
    tester,
  ) async {
    request.pending = Completer<String>();
    await open(tester);
    await tester.enterText(question(), 'old draft');
    await tester.tap(find.text('Send'));
    await tester.pump();
    await tester.pump();
    var cancelled = false;
    unawaited(request.cancelled!.then((_) => cancelled = true));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(QuickAskDialog), findsNothing);
    expect(cancelled, isTrue);
    request.pending!.complete('old result');
    request.pending = null;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('old result'), findsNothing);
    expect(tester.widget<EditableText>(question()).controller.text, isEmpty);
  });

  testWidgets(
    'a failed request gives a safe model/connection error and can retry',
    (tester) async {
      request.error = StateError('secret-provider-key');
      await open(tester);
      await send(tester);
      expect(find.textContaining('secret-provider-key'), findsNothing);
      expect(find.textContaining('Could not get an answer.'), findsOneWidget);
      request.error = null;
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.text('replacement'), findsOneWidget);
    },
  );

  testWidgets('theme changes update the open popup and small windows fit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previous = WorkbenchThemeService.instance;
    final themes = WorkbenchThemeService()..restore(setting: 'Bao Dark');
    WorkbenchThemeService.instance = themes;
    addTearDown(() => WorkbenchThemeService.instance = previous);
    await open(tester, locale: const Locale('zh'));
    Color? color() =>
        (tester
                    .widget<Container>(
                      find.byKey(const ValueKey('quick-ask-frame')),
                    )
                    .decoration
                as BoxDecoration)
            .color;
    final dark = color();
    await tester.runAsync(() => themes.setColorTheme('Bao Light'));
    await tester.pumpAndSettle();
    expect(color(), isNot(dark));
    expect(find.text('快捷提问 / 修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('quick-ask-frame'))).width,
      lessThan(420),
    );
  });
}
