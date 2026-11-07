import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:baocode/chat/widgets/markdown_view.dart';

import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/quick_ask/quick_ask_context.dart';
import 'package:baocode/quick_ask/quick_ask_files.dart';
import 'package:baocode/quick_ask/quick_ask_dialog.dart';
import 'package:baocode/quick_ask/quick_ask_service.dart';
import 'package:baocode/quick_ask/quick_ask_popup.dart';
import 'package:baocode/quick_ask/quick_ask_review.dart';
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
  void Function(String)? emit;

  Future<String> stream(
    String system,
    String prompt, {
    String? model,
    required bool exact,
    Future<void>? cancel,
    required void Function(String) onText,
  }) {
    emit = onText;
    return call(system, prompt, model: model, exact: exact, cancel: cancel);
  }

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
  final previewBoundary = GlobalKey();

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
    service = QuickAskService(
      request: request.call,
      streamRequest: request.stream,
      providers: providers,
    );
  });

  Future<void> open(
    WidgetTester tester, {
    QuickAskContext? source,
    Locale? locale,
    FutureOr<bool> Function(String prompt)? onAgentSubmit,
    String? agentLabel,
    Future<String?> Function()? pickFile,
    Future<QuickAskFileContext> Function(String path)? readFile,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: previewBoundary,
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Center(
              child: IdeButton(
                label: 'open',
                onPressed: () => unawaited(
                  showQuickAsk(
                    context,
                    source: source,
                    service: service,
                    onAgentSubmit: onAgentSubmit,
                    agentLabel: agentLabel,
                    pickFile: pickFile,
                    readFile: readFile,
                  ),
                ),
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

  Future<void> submit(WidgetTester tester) async {
    tester.widget<EditableText>(question()).focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester) async {
    await tester.enterText(question(), 'Explain this');
    await submit(tester);
  }

  Future<void> menu(WidgetTester tester) async {
    tester.widget<EditableText>(question()).focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.byType(QuickAskDialog), findsOneWidget);
  }

  Finder menuEntry(String label) => find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == label,
  );

  bool menuEnabled(WidgetTester tester, String label) =>
      tester.widget<Semantics>(menuEntry(label).last).properties.enabled!;

  Future<void> dismissMenu(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(QuickAskDialog), findsOneWidget);
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await menu(tester);
    await tester.ensureVisible(menuEntry(label).last);
    await tester.tap(menuEntry(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> mode(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.byKey(const ValueKey('quick-ask-mode')));
    await tester.tap(find.byKey(const ValueKey('quick-ask-mode')));
    await tester.pumpAndSettle();
    await tester.tap(menuEntry(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('picked files are reviewed and removable before explicit send', (
    tester,
  ) async {
    await open(
      tester,
      pickFile: () async => '/private/example.dart',
      readFile: (_) async => const QuickAskFileContext(
        name: 'example.dart',
        text: 'reference only',
      ),
    );
    await choose(tester, 'Add file…');
    expect(request.calls, 0);
    expect(find.text('reference only'), findsOneWidget);
    expect(
      find.textContaining('unsaved edits are not included'),
      findsOneWidget,
    );
    await send(tester);
    expect(request.input!['files'], [
      {'name': 'example.dart', 'text': 'reference only'},
    ]);
    expect(jsonEncode(request.input), isNot(contains('/private/')));
    await tester.ensureVisible(
      find.bySemanticsLabel('Remove example.dart').last,
    );
    await tester.tap(find.bySemanticsLabel('Remove example.dart').last);
    await tester.pumpAndSettle();
    await send(tester);
    expect(request.input!.containsKey('files'), isFalse);
  });

  testWidgets(
    'picker cancel, duplicate, failure and capacity keep bounded snapshots',
    (tester) async {
      String? path;
      var reads = 0;
      await open(
        tester,
        pickFile: () async => path,
        readFile: (path) async {
          reads++;
          if (path == 'bad') {
            throw const QuickAskFileException(QuickAskFileFailure.tooLarge);
          }
          return QuickAskFileContext(name: path, text: 'snapshot $path');
        },
      );
      await choose(tester, 'Add file…');
      expect(reads, 0);
      path = 'bad';
      await choose(tester, 'Add file…');
      expect(find.textContaining('This file was not added'), findsOneWidget);
      path = 'first';
      await choose(tester, 'Add file…');
      await choose(tester, 'Add file…');
      expect(reads, 2);
      for (path in ['second', 'third']) {
        await choose(tester, 'Add file…');
      }
      await menu(tester);
      expect(menuEnabled(tester, 'Add file…'), isFalse);
      await dismissMenu(tester);
      await send(tester);
      expect((request.input!['files'] as List).length, 3);
    },
  );

  testWidgets(
    'pending picker prevents send and ignores completion after close',
    (tester) async {
      final picked = Completer<String?>();
      var reads = 0;
      await open(
        tester,
        pickFile: () => picked.future,
        readFile: (_) async {
          reads++;
          return const QuickAskFileContext(name: 'a', text: 'b');
        },
      );
      await choose(tester, 'Add file…');
      await send(tester);
      expect(request.calls, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(QuickAskDialog), findsNothing);
      picked.complete('a');
      await tester.pumpAndSettle();
      expect(reads, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Agent receives selected file snapshots without local paths', (
    tester,
  ) async {
    String? prompt;
    await open(
      tester,
      onAgentSubmit: (value) {
        prompt = value;
        return true;
      },
      pickFile: () async => '/private/helper.dart',
      readFile: (_) async =>
          const QuickAskFileContext(name: 'helper.dart', text: 'reference'),
    );
    await choose(tester, 'Add file…');
    await mode(tester, 'Agent');
    await send(tester);
    final payload = jsonDecode(prompt!.split('\n').last) as Map;
    expect(payload['files'], [
      {'name': 'helper.dart', 'text': 'reference'},
    ]);
    expect(prompt, isNot(contains('/private/')));
    expect(request.calls, 0);
    expect(find.byType(QuickAskDialog), findsNothing);
  });

  testWidgets('failed file read after close does not update disposed UI', (
    tester,
  ) async {
    final read = Completer<QuickAskFileContext>();
    await open(tester, pickFile: () async => 'a', readFile: (_) => read.future);
    await choose(tester, 'Add file…');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    read.completeError(
      const QuickAskFileException(QuickAskFileFailure.unreadable),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(request.calls, 0);
  });

  testWidgets('pending file read is discarded after close', (tester) async {
    final read = Completer<QuickAskFileContext>();
    await open(tester, pickFile: () async => 'a', readFile: (_) => read.future);
    await choose(tester, 'Add file…');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    read.complete(const QuickAskFileContext(name: 'a', text: 'b'));
    await tester.pumpAndSettle();
    expect(find.byType(QuickAskDialog), findsNothing);
    expect(tester.takeException(), isNull);
    expect(request.calls, 0);
  });

  testWidgets(
    'one visible mode dropdown opens without sending or showing context',
    (tester) async {
      var handoffs = 0;
      await open(
        tester,
        source: const QuickAskContext(
          sourceLabel: 'private/source.dart',
          selectedText: 'private selection',
          contextText: 'private surroundings',
        ),
        onAgentSubmit: (_) {
          handoffs++;
          return true;
        },
      );
      expect(find.byType(QuickAskAction), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-ask-mode')), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      for (final hidden in [
        'Send',
        'Stop',
        'Ask',
        'Edit selection',
        'Review context',
        'private/source.dart',
        'private selection',
        'private surroundings',
      ]) {
        expect(find.text(hidden), findsNothing);
      }
      await mode(tester, 'Agent');
      expect(find.byType(QuickAskAction), findsOneWidget);
      expect(find.text('Agent'), findsOneWidget);
      expect(
        tester.widget<EditableText>(question()).focusNode.hasFocus,
        isTrue,
      );
      expect(handoffs, 0);
      expect(request.calls, 0);
    },
  );

  testWidgets('Agent sends bounded snapshots once and waits for acceptance', (
    tester,
  ) async {
    final prompts = <String>[];
    final accepted = Completer<bool>();
    var applied = false;
    await open(
      tester,
      source: QuickAskContext(
        sourceLabel: 's' * 500,
        selectedText: '${'x' * quickAskSelectionLimit}private remainder',
        contextText: '${'y' * quickAskContextLimit}private remainder',
        applyReplacement: (_) {
          applied = true;
          return true;
        },
      ),
      onAgentSubmit: (prompt) {
        prompts.add(prompt);
        return accepted.future;
      },
    );
    await mode(tester, 'Agent');
    await tester.enterText(question(), 'q' * quickAskQuestionLimit);
    expect(prompts, isEmpty);
    await submit(tester);
    expect(prompts, hasLength(1));
    final payload =
        jsonDecode(prompts.single.split('\n').last) as Map<String, dynamic>;
    expect(payload['request'], 'q' * quickAskQuestionLimit);
    expect(payload['selection'], 'x' * quickAskSelectionLimit);
    expect(payload['context'], 'y' * quickAskContextLimit);
    expect(payload['selectionTruncated'], isTrue);
    expect(payload['contextTruncated'], isTrue);
    expect((payload['source'] as String).length, 300);
    expect(prompts.single, isNot(contains('private remainder')));
    expect(prompts.single, contains('read its current contents'));
    expect(find.byType(QuickAskDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-ask-progress')), findsOneWidget);
    await submit(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(prompts, hasLength(1));
    expect(find.byType(QuickAskDialog), findsOneWidget);
    expect(request.calls, 0);
    expect(applied, isFalse);
    accepted.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(QuickAskDialog), findsNothing);
  });

  testWidgets(
    'Agent handoff respects independent selection and nearby switches',
    (tester) async {
      final prompts = <Map<String, dynamic>>[];
      await open(
        tester,
        source: const QuickAskContext(
          sourceLabel: 'Chat',
          selectedText: 'selected secret',
          contextText: 'nearby secret',
          truncated: true,
        ),
        onAgentSubmit: (prompt) {
          prompts.add(
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>,
          );
          return false;
        },
      );
      await mode(tester, 'Agent');
      await choose(tester, 'Selected excerpt');
      await choose(tester, 'Nearby context: on');
      await send(tester);
      expect(prompts.single['selection'], isEmpty);
      expect(prompts.single['context'], isEmpty);
      expect(prompts.single['selectionTruncated'], isFalse);
      expect(prompts.single['contextTruncated'], isFalse);
      await choose(tester, 'Selected excerpt');
      await submit(tester);
      expect(prompts, hasLength(2));
      expect(prompts.last['selection'], 'selected secret');
      expect(prompts.last['selectionTruncated'], isTrue);
      expect(prompts.last['context'], isEmpty);
      expect(request.calls, 0);
    },
  );

  testWidgets('Agent is disabled without a workspace handoff callback', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('quick-ask-mode')));
    await tester.pumpAndSettle();
    expect(menuEnabled(tester, 'Agent'), isFalse);
    await tester.tap(menuEntry('Agent'));
    await tester.pumpAndSettle();
    expect(request.calls, 0);
    await dismissMenu(tester);
    expect(find.text('Chat'), findsOneWidget);
    await send(tester);
    expect(request.calls, 1);
  });

  for (final throws in [false, true]) {
    testWidgets(
      'failed Agent handoff (throws: $throws) stays open without fallback',
      (tester) async {
        var calls = 0;
        await open(
          tester,
          onAgentSubmit: (_) {
            calls++;
            if (throws) throw StateError('private agent credential');
            return false;
          },
        );
        await mode(tester, 'Agent');
        await send(tester);
        expect(calls, 1);
        expect(request.calls, 0);
        expect(find.byType(QuickAskDialog), findsOneWidget);
        expect(
          find.textContaining('Could not hand off to Agent.'),
          findsOneWidget,
        );
        expect(find.textContaining('private agent credential'), findsNothing);
        expect(
          tester.widget<EditableText>(question()).controller.text,
          'Explain this',
        );
        await tester.pump(const Duration(seconds: 2));
        expect(calls, 1);
        expect(request.calls, 0);
      },
    );
  }

  testWidgets('invalid Agent questions do not call either backend', (
    tester,
  ) async {
    var calls = 0;
    await open(
      tester,
      onAgentSubmit: (_) {
        calls++;
        return true;
      },
    );
    await mode(tester, 'Agent');
    for (final value in ['   ', 'x' * (quickAskQuestionLimit + 1)]) {
      await tester.enterText(question(), value);
      await submit(tester);
      expect(calls, 0);
      expect(request.calls, 0);
      expect(find.byType(QuickAskDialog), findsOneWidget);
    }
  });

  for (final modifier in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.metaLeft,
  ]) {
    testWidgets('${modifier.keyLabel}+Enter submits exactly once', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(question(), 'Explain this');
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      expect(request.calls, 1);
      expect(
        tester.widget<EditableText>(question()).controller.text,
        'Explain this',
      );
    });
  }

  testWidgets('switching Chat and Agent clears previews and resets edit mode', (
    tester,
  ) async {
    var calls = 0;
    await open(
      tester,
      source: const QuickAskContext(
        sourceLabel: 'Chat',
        selectedText: 'original',
      ),
      onAgentSubmit: (_) {
        calls++;
        return false;
      },
    );
    await choose(tester, 'Edit selection');
    await send(tester);
    expect(request.input!['mode'], 'edit');
    expect(find.byType(QuickAskReview), findsOneWidget);
    await mode(tester, 'Agent');
    expect(find.text('replacement'), findsNothing);
    expect(find.byKey(const ValueKey('quick-ask-replacement')), findsNothing);
    await menu(tester);
    expect(menuEntry('Edit selection'), findsNothing);
    expect(menuEntry('Same as Auxiliary Model'), findsNothing);
    await dismissMenu(tester);
    await mode(tester, 'Chat');
    await submit(tester);
    expect(request.input!['mode'], 'ask');
    expect(find.byType(MarkdownView), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets(
    'a stale Chat model fails without sending excerpts to a fallback',
    (tester) async {
      await providers.setQuickAskModel('@missing/model');
      await open(
        tester,
        source: const QuickAskContext(
          sourceLabel: 'file',
          selectedText: 'private selection',
        ),
      );
      await send(tester);
      expect(request.calls, 0);
      expect(find.textContaining('Could not get an answer.'), findsOneWidget);
    },
  );

  testWidgets(
    'Shift+Enter inserts a newline; IME Enter and Escape do not submit or close',
    (tester) async {
      await open(tester);
      await tester.enterText(question(), 'first');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(
        tester.widget<EditableText>(question()).controller.text,
        'first\n',
      );
      expect(request.calls, 0);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '拼音',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(
        tester.widget<EditableText>(question()).controller.value,
        const TextEditingValue(
          text: '拼音',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(request.calls, 0);
      expect(find.byType(QuickAskDialog), findsOneWidget);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '拼音',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      await submit(tester);
      expect(request.calls, 1);
      expect(request.input!['request'], '拼音');
    },
  );

  testWidgets('Shift+Enter replaces only the selected question range', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(question(), 'first second');
    final controller = tester.widget<EditableText>(question()).controller;
    controller.selection = const TextSelection(baseOffset: 5, extentOffset: 12);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(controller.text, 'first\n');
    expect(controller.selection, const TextSelection.collapsed(offset: 6));
    expect(request.calls, 0);
  });

  testWidgets(
    'mode dropdown and secondary Send are usable with only the keyboard',
    (tester) async {
      var calls = 0;
      await open(
        tester,
        onAgentSubmit: (_) {
          calls++;
          return false;
        },
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(menuEntry('Agent'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Agent'), findsOneWidget);
      expect(calls, 0);
      await tester.enterText(question(), 'Do this');
      await menu(tester);
      expect(menuEntry('Send'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(request.calls, 0);
      expect(find.byType(QuickAskDialog), findsOneWidget);
    },
  );

  testWidgets(
    'right-click secondary menu preserves the popup and context remains optional',
    (tester) async {
      await open(
        tester,
        source: const QuickAskContext(
          sourceLabel: 'file',
          selectedText: 'selected',
        ),
      );
      final frame = tester.getRect(
        find.byKey(const ValueKey('quick-ask-frame')),
      );
      await tester.tapAt(
        frame.bottomRight - const Offset(5, 5),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.byType(QuickAskDialog), findsOneWidget);
      expect(menuEntry('Review context'), findsOneWidget);
      expect(find.text('selected'), findsNothing);
      await tester.tap(menuEntry('Review context'));
      await tester.pumpAndSettle();
      expect(find.text('selected'), findsOneWidget);
      expect(find.byType(QuickAskDialog), findsOneWidget);
      await menu(tester);
      await dismissMenu(tester);
      expect(request.calls, 0);
    },
  );

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
      await menu(tester);
      await tester.tap(menuEntry('Same as Auxiliary Model'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Codicons.menuSelection), findsNWidgets(2));
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
      await choose(tester, 'Review context');
      await tester.pumpAndSettle();
      expect(find.text('selected'), findsOneWidget);
      expect(find.text('nearby'), findsOneWidget);
      await choose(tester, 'Nearby context: on');
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
    await choose(tester, 'Edit selection');
    await send(tester);
    expect(request.input!['mode'], 'edit');
    expect(applied, isEmpty);
    expect(find.text('− original'), findsOneWidget);
    await choose(tester, 'Proposed replacement (editable)');
    final replacement = find.descendant(
      of: find.byKey(const ValueKey('quick-ask-replacement')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(replacement, 'reviewed replacement');
    await choose(tester, 'Apply replacement');
    await tester.pumpAndSettle();
    expect(applied, ['reviewed replacement']);
    await menu(tester);
    expect(menuEnabled(tester, 'Applied'), isFalse);
    await dismissMenu(tester);
    await tester.pumpAndSettle();
    expect(applied, hasLength(1));
  });

  testWidgets('review choices are reversible and apply only kept hunks once', (
    tester,
  ) async {
    request.pending = Completer<String>()..complete('FIRST\nsame\nLAST\n');
    final applied = <String>[];
    final applying = Completer<bool>();
    await open(
      tester,
      source: QuickAskContext(
        sourceLabel: 'file.dart',
        selectedText: 'first\nsame\nlast\n',
        applyReplacement: (text) {
          applied.add(text);
          return applying.future;
        },
      ),
    );
    await choose(tester, 'Edit selection');
    await send(tester);
    expect(find.byType(QuickAskReview), findsOneWidget);
    expect(applied, isEmpty);
    Future<void> press(String key) async {
      final found = find.byKey(ValueKey(key));
      await tester.ensureVisible(found);
      await tester.tap(found);
      await tester.pumpAndSettle();
    }

    await press('quick-ask-reject-0');
    await press('quick-ask-reject-1');
    expect(
      tester
          .widget<QuickAskAction>(find.byKey(const ValueKey('quick-ask-apply')))
          .onPressed,
      isNull,
    );
    await press('quick-ask-keep-1');
    expect(applied, isEmpty);
    await press('quick-ask-apply');
    expect(applied, ['first\nsame\nLAST\n']);
    await press('quick-ask-apply');
    await press('quick-ask-keep-0');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(QuickAskDialog), findsOneWidget);
    expect(applied, hasLength(1));
    applying.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(QuickAskReview), findsNothing);
    expect(find.text('first\nsame\nLAST\n'), findsOneWidget);
  });

  testWidgets('manual proposal editing preserves rejected hunks', (
    tester,
  ) async {
    request.pending = Completer<String>()..complete('FIRST\nsame\nLAST\n');
    final applied = <String>[];
    await open(
      tester,
      source: QuickAskContext(
        sourceLabel: 'file.dart',
        selectedText: 'first\nsame\nlast\n',
        applyReplacement: (text) {
          applied.add(text);
          return true;
        },
      ),
    );
    await choose(tester, 'Edit selection');
    await send(tester);
    final reject = find.byKey(const ValueKey('quick-ask-reject-0'));
    await tester.ensureVisible(reject);
    await tester.tap(reject);
    await tester.pumpAndSettle();
    await choose(tester, 'Proposed replacement (editable)');
    final input = find.descendant(
      of: find.byKey(const ValueKey('quick-ask-replacement')),
      matching: find.byType(EditableText),
    );
    expect(
      tester.widget<EditableText>(input).controller.text,
      'first\nsame\nLAST\n',
    );
    await tester.enterText(input, 'first\nsame\nLAST reviewed\n');
    await choose(tester, 'Apply replacement');
    expect(applied, ['first\nsame\nLAST reviewed\n']);
  });

  testWidgets(
    'rejecting with proposal editor open cannot revive discarded text',
    (tester) async {
      request.pending = Completer<String>()..complete('FIRST\nsame\nLAST\n');
      final applied = <String>[];
      await open(
        tester,
        source: QuickAskContext(
          sourceLabel: 'file.dart',
          selectedText: 'first\nsame\nlast\n',
          applyReplacement: (text) {
            applied.add(text);
            return true;
          },
        ),
      );
      await choose(tester, 'Edit selection');
      await send(tester);
      await choose(tester, 'Proposed replacement (editable)');
      final reject = find.byKey(const ValueKey('quick-ask-reject-0'));
      await tester.ensureVisible(reject);
      await tester.tap(reject);
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byKey(const ValueKey('quick-ask-replacement')),
        matching: find.byType(EditableText),
      );
      expect(
        tester.widget<EditableText>(input).controller.text,
        'first\nsame\nLAST\n',
      );
      await tester.enterText(
        input,
        '${tester.widget<EditableText>(input).controller.text}!',
      );
      await choose(tester, 'Apply replacement');
      expect(applied, ['first\nsame\nLAST\n!']);
    },
  );

  testWidgets('identical output has no enabled apply action', (tester) async {
    request.pending = Completer<String>()..complete('original');
    var applied = 0;
    await open(
      tester,
      source: QuickAskContext(
        sourceLabel: 'file.dart',
        selectedText: 'original',
        applyReplacement: (_) {
          applied++;
          return true;
        },
      ),
    );
    await choose(tester, 'Edit selection');
    await send(tester);
    expect(find.text('No differences'), findsOneWidget);
    await menu(tester);
    expect(menuEnabled(tester, 'Apply replacement'), isFalse);
    expect(applied, 0);
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
      await choose(tester, 'Edit selection');
      await send(tester);
      await choose(tester, 'Apply replacement');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The source changed or closed.'),
        findsOneWidget,
      );
      expect(find.byType(QuickAskReview), findsOneWidget);
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
      await choose(tester, 'Edit selection');
      await send(tester);
      expect(find.byType(QuickAskReview), findsOneWidget);
      expect(find.bySemanticsLabel('Apply replacement'), findsNothing);
      expect(find.textContaining('This source is read-only'), findsNothing);
      await menu(tester);
      expect(menuEntry('Copy'), findsOneWidget);
      expect(menuEntry('Apply replacement'), findsNothing);
      await dismissMenu(tester);
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
    await menu(tester);
    expect(menuEnabled(tester, 'Edit selection'), isFalse);
    await dismissMenu(tester);
    await send(tester);
    expect(request.input!['selectionTruncated'], isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await open(tester);
    await menu(tester);
    expect(menuEnabled(tester, 'Edit selection'), isFalse);
    await dismissMenu(tester);
  });

  testWidgets(
    'streams before completion and never applies a stopped partial edit',
    (tester) async {
      request.pending = Completer<String>();
      var applications = 0;
      await open(
        tester,
        source: QuickAskContext(
          sourceLabel: 'file',
          selectedText: 'original',
          applyReplacement: (_) {
            applications++;
            return true;
          },
        ),
      );
      await choose(tester, 'Edit selection');
      await send(tester);
      request.emit!('Partial replacement');
      await tester.pump();
      expect(find.text('Partial replacement'), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-ask-progress')), findsOneWidget);
      await menu(tester);
      expect(menuEnabled(tester, 'Apply replacement'), isFalse);
      await dismissMenu(tester);
      await choose(tester, 'Stop');
      await tester.pumpAndSettle();
      await menu(tester);
      expect(menuEnabled(tester, 'Apply replacement'), isFalse);
      await dismissMenu(tester);
      request.emit!('stale chunk');
      request.pending!.complete('stale final');
      request.pending = null;
      await tester.pumpAndSettle();
      expect(find.text('stale chunk'), findsNothing);
      expect(find.text('stale final'), findsNothing);
      expect(applications, 0);
      await send(tester);
      await menu(tester);
      expect(menuEnabled(tester, 'Apply replacement'), isTrue);
      await dismissMenu(tester);
    },
  );

  testWidgets('streaming follows the bottom but preserves reading position', (
    tester,
  ) async {
    request.pending = Completer<String>();
    await open(tester);
    await send(tester);
    String answer(int count) => List.generate(
      count,
      (i) => 'Paragraph $i with enough text to wrap across the compact answer.',
    ).join('\n\n');
    request.emit!(answer(20));
    await tester.pump();
    await tester.pump();
    final scroll = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('quick-ask-scroll')),
        )
        .controller!;
    expect(scroll.position.extentAfter, lessThan(1));
    scroll.jumpTo(80);
    await tester.pump();
    request.emit!(answer(25));
    await tester.pump();
    await tester.pump();
    expect(scroll.offset, 80);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    request.emit!(answer(30));
    await tester.pump();
    await tester.pump();
    expect(scroll.position.extentAfter, lessThan(1));
    request.pending!.complete(answer(30));
    await tester.pumpAndSettle();
  });

  testWidgets('markdown never loads remote images automatically', (
    tester,
  ) async {
    request.pending = Completer<String>();
    await open(tester);
    await send(tester);
    request.emit!(
      '![remote image](https://example.invalid/tracker.png)\n\n[Reference](https://example.invalid/reference)',
    );
    await tester.pumpAndSettle();
    // The shared renderer represents web images as alt text (or explicit
    // links in a file scope), never fetching them on receiving model output.
    expect(
      find.descendant(
        of: find.byType(QuickAskDialog),
        matching: find.byType(Image),
      ),
      findsNothing,
    );
    expect(find.text('[remote image]'), findsOneWidget);
    expect(find.bySemanticsLabel('Loading...'), findsOneWidget);
    request.pending!.complete('Done');
    await tester.pumpAndSettle();
  });

  testWidgets('failed streamed edits stay read only; close ignores chunks', (
    tester,
  ) async {
    request.pending = Completer<String>();
    await open(
      tester,
      source: QuickAskContext(
        sourceLabel: 'file',
        selectedText: 'original',
        applyReplacement: (_) => true,
      ),
    );
    await choose(tester, 'Edit selection');
    await send(tester);
    request.emit!('Incomplete');
    await tester.pump();
    request.pending!.completeError(StateError('private'));
    await tester.pumpAndSettle();
    await menu(tester);
    expect(menuEnabled(tester, 'Apply replacement'), isFalse);
    await dismissMenu(tester);
    expect(find.textContaining('Could not get an answer.'), findsOneWidget);
    request.pending = Completer<String>();
    await send(tester);
    final emit = request.emit!;
    await choose(tester, 'Close Dialog');
    await tester.pumpAndSettle();
    emit('late');
    request.pending!.complete('late');
    await tester.pumpAndSettle();
    expect(find.byType(QuickAskDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final theme in ['Bao Dark', 'Bao Light']) {
    testWidgets('renders $theme compact and streamed markdown preview', (
      tester,
    ) async {
      if (const bool.fromEnvironment('QUICK_ASK_PREVIEWS')) {
        await tester.runAsync(() async {
          final paths = [
            '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
            '/System/Library/Fonts/Supplemental/Arial.ttf',
            r'C:\Windows\Fonts\arial.ttf',
          ];
          final body = paths
              .map(File.new)
              .where((file) => file.existsSync())
              .firstOrNull;
          for (final (family, file) in [
            if (body != null) ('Roboto', body),
            (
              'monospace',
              File('assets/fonts/maple/MapleMonoNormal-NF-CN-Regular.ttf'),
            ),
            (Codicons.fontFamily, File('assets/codicons/codicon.ttf')),
          ]) {
            await (FontLoader(family)..addFont(
                  Future.value(ByteData.sublistView(file.readAsBytesSync())),
                ))
                .load();
          }
        });
      }
      final previous = WorkbenchThemeService.instance;
      final themes = WorkbenchThemeService()..restore(setting: theme);
      WorkbenchThemeService.instance = themes;
      addTearDown(() => WorkbenchThemeService.instance = previous);
      await open(
        tester,
        source: QuickAskContext(
          sourceLabel: 'editor',
          selectedText: 'final old = 1;\nprint(old);\nreturn false;',
          contextText: 'nearby',
          applyReplacement: (_) => true,
          selectionAnchor: () => const Rect.fromLTWH(100, 100, 1, 18),
        ),
        onAgentSubmit: (_) => true,
        agentLabel: 'Codex · Example project',
        pickFile: () async => '/example/helper.dart',
        readFile: (_) async => const QuickAskFileContext(
          name: 'helper.dart',
          text: 'int helper() => 42;',
        ),
      );
      Future<void> capture(String name) async {
        if (!const bool.fromEnvironment('QUICK_ASK_PREVIEWS')) return;
        final captured = find.byKey(previewBoundary);
        expect(
          find.descendant(
            of: captured,
            matching: find.byKey(const ValueKey('quick-ask-frame')),
          ),
          findsOneWidget,
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(captured);
        await tester.runAsync(() {
          return (() async {
            final image = await boundary.toImage();
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File('build/quick-ask-previews/$name.png');
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          })().timeout(const Duration(seconds: 15));
        });
      }

      await capture('$theme-composer');
      request.pending = Completer<String>();
      await send(tester);
      request.emit!(
        '**Selection explained**\n\nA compact answer with readable spacing.\n\n- Markdown stays readable.\n- The selection stays in view.',
      );
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownView), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-ask-progress')), findsOneWidget);
      await capture('$theme-streaming');
      request.pending!.complete(
        '**Selection explained**\n\nA compact answer with readable spacing.\n\n- Markdown stays readable.\n- The selection stays in view.',
      );
      await tester.pumpAndSettle();
      await capture('$theme-complete');
      await mode(tester, 'Agent');
      await capture('$theme-agent-composer');
      expect(find.byType(QuickAskAction), findsOneWidget);
      expect(request.calls, 1);
      await mode(tester, 'Chat');
      await choose(tester, 'Edit selection');
      request.pending = Completer<String>()
        ..complete('final value = 2;\nprint(old);\nreturn true;');
      await send(tester);
      await capture('$theme-edit-review');
      expect(find.byType(QuickAskReview), findsOneWidget);
      final applyLabel = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('quick-ask-apply')),
          matching: find.text('Apply replacement'),
        ),
      );
      expect(applyLabel.style!.color, themeColors['button.foreground']);
      await mode(tester, 'Chat');
      await choose(tester, 'Add file…');
      await capture('$theme-file-context');
      await tester.ensureVisible(find.text('int helper() => 42;'));
      await tester.pumpAndSettle();
      await capture('$theme-file-context-details');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('stop discards a late answer and permits a fresh request', (
    tester,
  ) async {
    request.pending = Completer<String>();
    await open(tester);
    await tester.enterText(question(), 'Explain');
    await submit(tester);
    await tester.pump();
    await tester.pump();
    expect(request.calls, 1);
    var cancelled = false;
    unawaited(request.cancelled!.then((_) => cancelled = true));
    await choose(tester, 'Stop');
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
    request.pending!.complete('late result');
    request.pending = null;
    await tester.pumpAndSettle();
    expect(find.text('late result'), findsNothing);
    await submit(tester);
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
    await submit(tester);
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
      await submit(tester);
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
    await menu(tester);
    expect(menuEntry('发送'), findsOneWidget);
    await dismissMenu(tester);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('quick-ask-frame'))).width,
      lessThan(420),
    );
  });

  testWidgets(
    'narrow viewport with large text retains named keyboard controls',
    (tester) async {
      tester.view.physicalSize = const Size(220, 260);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(
        tester,
        source: const QuickAskContext(
          sourceLabel: 'editor',
          selectedText: 'selection',
          contextText: 'nearby',
        ),
      );
      expect(find.byType(QuickAskAction), findsOneWidget);
      expect(find.bySemanticsLabel('Chat'), findsOneWidget);
      await menu(tester);
      expect(tester.takeException(), isNull);
      for (final label in [
        'Ask',
        'Edit selection',
        'Review context',
        'Send',
        'Close Dialog',
      ]) {
        expect(menuEntry(label), findsOneWidget);
      }
      await dismissMenu(tester);
      final frame = tester.getRect(
        find.byKey(const ValueKey('quick-ask-frame')),
      );
      expect(frame.left, greaterThanOrEqualTo(8));
      expect(frame.right, lessThanOrEqualTo(212));
      expect(frame.bottom, lessThanOrEqualTo(252));
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(QuickAskDialog), findsNothing);
    },
  );

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
    expect(frame.height, lessThan(105));
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
      findsOneWidget,
    );
    expect(find.text('Chat'), findsOneWidget);
    expect(find.byType(QuickAskAction), findsOneWidget);
    expect(tester.widget<EditableText>(question()).focusNode.hasFocus, isTrue);
    expect(find.bySemanticsLabel('Send'), findsNothing);
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
      await submit(tester);
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
      await menu(tester);
      expect(menuEntry('发送'), findsOneWidget);
      await dismissMenu(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
