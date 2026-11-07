import 'dart:async';
import 'dart:convert';

import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/quick_ask/quick_ask_context.dart';
import 'package:baocode/quick_ask/quick_ask_dialog.dart';
import 'package:baocode/quick_ask/quick_ask_service.dart';
import 'package:baocode/quick_ask/quick_ask_popup.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide ColorScheme;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Request {
  int calls = 0;
  Map<String, dynamic>? input;
  String? model;
  bool? exact;
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
    this.model = model;
    this.exact = exact;
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
          models: [
            ProviderModel(id: 'small'),
            ProviderModel(id: 'chat'),
            ProviderModel(id: 'quick'),
          ],
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
    await tester.ensureVisible(find.bySemanticsLabel('Send'));
    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'automatic model follows captured chat and explicit quick ask wins',
    (tester) async {
      await providers.setDefaultModel('@test/small');
      await providers.setAuxiliaryModel(null);
      await providers.setQuickAskModel(ModelProviders.followAuxiliary);
      await open(
        tester,
        source: const QuickAskContext(
          sourceLabel: 'Chat',
          selectedText: 'selected message',
          sessionModel: '@test/chat',
        ),
      );
      await send(tester);
      expect(request.model, '@test/chat');
      expect(request.exact, isFalse);
      expect(request.input!['selection'], 'selected message');
      await providers.setQuickAskModel('@test/quick');
      await tester.pumpAndSettle();
      await send(tester);
      expect(request.model, '@test/quick');
      expect(request.exact, isTrue);
      expect(providers.defaultModel, '@test/small');
      expect(providers.auxiliaryModel, isNull);
    },
  );

  for (final stored in [null, ModelProviders.followAuxiliary]) {
    testWidgets('model menu checks auxiliary default stored as $stored', (
      tester,
    ) async {
      await providers.setQuickAskModel(stored);
      await open(tester);
      await tester.tap(find.bySemanticsLabel('Same as Auxiliary Model'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Codicons.menuSelection), findsOneWidget);
      await tester.tap(find.text('Same as Auxiliary Model').last);
      await tester.pumpAndSettle();
      expect(providers.quickAskModel, ModelProviders.followAuxiliary);
      expect(request.calls, 0);
    });
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
      await tester.tap(find.bySemanticsLabel('Review context'));
      await tester.pumpAndSettle();
      expect(find.text('selected'), findsOneWidget);
      expect(find.text('nearby'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Nearby context: on'));
      await tester.pumpAndSettle();
      expect(find.text('nearby'), findsNothing);
      await send(tester);
      expect(request.calls, 1);
      expect(request.input!['selection'], 'selected');
      expect(request.input!['context'], '');
      expect(find.text('replacement'), findsOneWidget);
      expect(find.bySemanticsLabel('Apply replacement'), findsNothing);
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
    await tester.tap(find.bySemanticsLabel('Edit selection'));
    await send(tester);
    expect(request.input!['mode'], 'edit');
    expect(applied, isEmpty);
    expect(find.text('original'), findsOneWidget);
    final replacement = find.descendant(
      of: find.byKey(const ValueKey('quick-ask-replacement')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(replacement, 'reviewed replacement');
    await tester.ensureVisible(find.bySemanticsLabel('Apply replacement'));
    await tester.tap(find.bySemanticsLabel('Apply replacement'));
    await tester.pumpAndSettle();
    expect(applied, ['reviewed replacement']);
    await tester.tap(find.bySemanticsLabel('Applied'));
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
      await tester.tap(find.bySemanticsLabel('Edit selection'));
      await send(tester);
      await tester.ensureVisible(find.bySemanticsLabel('Apply replacement'));
      await tester.tap(find.bySemanticsLabel('Apply replacement'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The source changed or closed.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('quick-ask-replacement')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Applied'), findsNothing);
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
      await tester.tap(find.bySemanticsLabel('Edit selection'));
      await send(tester);
      expect(
        find.byKey(const ValueKey('quick-ask-replacement')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Apply replacement'), findsNothing);
      expect(find.textContaining('This source is read-only'), findsNothing);
      expect(find.bySemanticsLabel('Copy'), findsOneWidget);
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
    final edit = tester.widget<QuickAskAction>(
      find.widgetWithIcon(QuickAskAction, Codicons.edit),
    );
    expect(edit.onPressed, isNull);
    await send(tester);
    expect(request.input!['selectionTruncated'], isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await open(tester);
    final noSelection = tester.widget<QuickAskAction>(
      find.widgetWithIcon(QuickAskAction, Codicons.edit),
    );
    expect(noSelection.onPressed, isNull);
  });

  testWidgets('stop discards a late answer and permits a fresh request', (
    tester,
  ) async {
    request.pending = Completer<String>();
    await open(tester);
    await tester.enterText(question(), 'Explain');
    await tester.ensureVisible(find.bySemanticsLabel('Send'));
    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pump();
    await tester.pump();
    expect(request.calls, 1);
    var cancelled = false;
    unawaited(request.cancelled!.then((_) => cancelled = true));
    await tester.tap(find.bySemanticsLabel('Stop'));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
    request.pending!.complete('late result');
    request.pending = null;
    await tester.pumpAndSettle();
    expect(find.text('late result'), findsNothing);
    await tester.ensureVisible(find.bySemanticsLabel('Send'));
    await tester.tap(find.bySemanticsLabel('Send'));
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
    await tester.ensureVisible(find.bySemanticsLabel('Send'));
    await tester.tap(find.bySemanticsLabel('Send'));
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
      await tester.ensureVisible(find.bySemanticsLabel('Send'));
      await tester.tap(find.bySemanticsLabel('Send'));
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
    expect(find.text('快捷提问 / 修改'), findsNothing);
    expect(find.bySemanticsLabel('发送'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('quick-ask-frame'))).width,
      lessThan(420),
    );
  });

  testWidgets('opens beside the selected end without a modal scrim or hints', (
    tester,
  ) async {
    await open(
      tester,
      source: QuickAskContext(
        sourceLabel: 'private/path.dart',
        selectedText: 'selection',
        contextText: 'nearby',
        selectionAnchor: () => const Rect.fromLTWH(210, 120, 1, 18),
      ),
    );
    final frame = tester.getRect(find.byKey(const ValueKey('quick-ask-frame')));
    expect(frame.left, 210);
    expect(frame.top, 144);
    expect(frame.width, 320);
    expect(frame.height, lessThan(90));
    expect(
      find.descendant(
        of: find.byType(QuickAskDialog),
        matching: find.byType(ModalBarrier),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(QuickAskDialog),
        matching: find.byType(Text),
      ),
      findsNothing,
    );
    expect(tester.widget<EditableText>(question()).focusNode.hasFocus, isTrue);
    expect(find.bySemanticsLabel('Send'), findsOneWidget);
    expect(request.calls, 0);
  });

  testWidgets(
    'moves with selection geometry, flips and clamps after resizing',
    (tester) async {
      final anchor = ValueNotifier(const Rect.fromLTWH(50, 80, 1, 18));
      addTearDown(anchor.dispose);
      await open(
        tester,
        source: QuickAskContext(
          sourceLabel: 'editor',
          selectionAnchor: () => anchor.value,
          selectionAnchorListenable: anchor,
        ),
      );
      Rect frame() =>
          tester.getRect(find.byKey(const ValueKey('quick-ask-frame')));
      expect(frame().topLeft, const Offset(50, 104));
      anchor.value = const Rect.fromLTWH(130, 200, 1, 18);
      await tester.pumpAndSettle();
      expect(frame().topLeft, const Offset(130, 224));
      anchor.value = const Rect.fromLTWH(790, 580, 1, 18);
      await tester.pumpAndSettle();
      expect(frame().right, lessThanOrEqualTo(792));
      expect(frame().bottom, 574);
      tester.view.physicalSize = const Size(240, 180);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      expect(frame().right, lessThanOrEqualTo(232));
      expect(frame().bottom, lessThanOrEqualTo(172));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an unavailable source keeps the last location and cancels on outside click',
    (tester) async {
      final anchor = ValueNotifier<Rect?>(const Rect.fromLTWH(30, 100, 1, 18));
      addTearDown(anchor.dispose);
      request.pending = Completer<String>();
      await open(
        tester,
        source: QuickAskContext(
          sourceLabel: 'editor',
          selectionAnchor: () => anchor.value,
          selectionAnchorListenable: anchor,
        ),
      );
      final before = tester.getTopLeft(
        find.byKey(const ValueKey('quick-ask-frame')),
      );
      anchor.value = null;
      await tester.pump();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('quick-ask-frame'))),
        before,
      );
      await tester.enterText(question(), 'Explain');
      await tester.tap(find.bySemanticsLabel('Send'));
      await tester.pump();
      var cancelled = false;
      unawaited(request.cancelled!.then((_) => cancelled = true));
      await tester.tapAt(const Offset(750, 50));
      await tester.pumpAndSettle();
      expect(find.byType(QuickAskDialog), findsNothing);
      expect(cancelled, isTrue);
      request.pending!.complete('late');
      await tester.pumpAndSettle();
      expect(find.text('late'), findsNothing);
    },
  );

  testWidgets(
    'keyboard send and Escape restore source focus without navigating',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final controller = TextEditingController(text: 'source');
      addTearDown(controller.dispose);
      late BuildContext page;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              page = context;
              return Material(
                child: TextField(focusNode: focus, controller: controller),
              );
            },
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      unawaited(showQuickAsk(page, service: service));
      await tester.pumpAndSettle();
      await tester.enterText(question(), 'Explain');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(request.calls, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      expect(Navigator.of(page).canPop(), isFalse);
      expect(controller.text, 'source');
    },
  );

  testWidgets(
    'scrolls the source behind the popup and follows its live transform',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final selected = GlobalKey();
      late BuildContext page;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              page = context;
              return SingleChildScrollView(
                controller: scroll,
                child: SizedBox(
                  height: 1600,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 100,
                        top: 200,
                        child: SizedBox(key: selected, width: 1, height: 18),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      Rect anchor() {
        final box = selected.currentContext!.findRenderObject()! as RenderBox;
        return box.localToGlobal(Offset.zero) & box.size;
      }

      unawaited(
        showQuickAsk(
          page,
          service: service,
          source: QuickAskContext(
            sourceLabel: 'editor',
            selectionAnchor: anchor,
            selectionAnchorListenable: scroll,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('quick-ask-frame'))),
        const Offset(100, 224),
      );
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(50, 350),
          scrollDelta: Offset(0, 80),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, 80);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('quick-ask-frame'))),
        const Offset(100, 144),
      );
      expect(find.byType(QuickAskDialog), findsOneWidget);
    },
  );

  testWidgets(
    'owner disposal completes pending popup and preserves overridden locale',
    (tester) async {
      late BuildContext page;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Localizations.override(
              context: context,
              locale: const Locale('zh'),
              child: Builder(
                builder: (context) {
                  page = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      var closed = false;
      unawaited(
        showQuickAsk(page, service: service).then((_) => closed = true),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('发送'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
