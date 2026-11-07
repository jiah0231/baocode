import 'dart:async';
import 'dart:convert';

import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/composer/composer_controller.dart';
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/chat/composer/composer_embeds.dart';
import 'package:baocode/chat/composer/composer_files.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/quick_ask/quick_ask_context.dart';
import 'package:baocode/quick_ask/quick_ask_dialog.dart';
import 'package:baocode/quick_ask/quick_ask_service.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ChatSession _session() {
  final session = ChatSession(historyCount: 0);
  addTearDown(session.dispose);
  return session;
}

Finder _editor() => find.descendant(
  of: find.byType(ChatComposer),
  matching: find.byType(MarkdownEditor),
);

Future<ComposerController> _pumpComposer(
  WidgetTester tester,
  ChatSession session, {
  ComposerDraft? draft,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ChatComposer(session: session, draft: draft ?? session.draft),
      ),
    ),
  );
  await tester.pump();
  return tester.widget<MarkdownEditor>(_editor()).controller
      as ComposerController;
}

Future<QuickAskContext> _capture(
  WidgetTester tester,
  ComposerController controller,
  String text, {
  int start = 7,
  int end = 13,
}) async {
  controller.replace(0, controller.length, text);
  controller.selection = TextSelection(baseOffset: start, extentOffset: end);
  tester.state<ChatComposerState>(find.byType(ChatComposer)).focus();
  await tester.pump();
  expect(tester.widget<MarkdownEditor>(_editor()).focusNode!.hasFocus, isTrue);
  return QuickAskContext.captureFocused()!;
}

Finder _input(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(EditableText),
);

Finder _menuEntry(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
);

Future<void> _openSecondaryMenu(WidgetTester tester) async {
  tester
      .widget<EditableText>(_input('quick-ask-question'))
      .focusNode
      .requestFocus();
  await tester.pump();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.f10);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pumpAndSettle();
}

Future<void> _chooseSecondary(WidgetTester tester, String label) async {
  await _openSecondaryMenu(tester);
  await tester.ensureVisible(_menuEntry(label).last);
  await tester.tap(_menuEntry(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('anchor uses reverse selection extent and survives focus loss', (
    tester,
  ) async {
    final session = _session();
    final controller = await _pumpComposer(tester, session);
    final source = await _capture(
      tester,
      controller,
      'before chosen after',
      start: 13,
      end: 7,
    );
    final editor = tester.state<MarkdownEditorState>(_editor());
    final expected = editor.caretRect(7);
    expect(expected, isNotNull);
    expect(source.selectionAnchor!(), expected);
    expect(source.selectionAnchorListenable, isNotNull);
    tester.widget<MarkdownEditor>(_editor()).focusNode!.unfocus();
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    expect(source.selectionAnchor!(), expected);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    expect(source.selectionAnchor!(), isNull);
  });

  testWidgets('an empty focused composer keeps its session model route', (
    tester,
  ) async {
    final session = _session();
    await _pumpComposer(tester, session);
    expect(session.models, isNotNull);
    final source = QuickAskContext.captureFocused()!;
    expect(source.sourceLabel, 'Chat');
    expect(source.sessionModel, session.models!.selected.id);
    expect(source.selectedText, isEmpty);
    expect(source.contextText, isEmpty);
    expect(source.canApply, isFalse);
  });

  testWidgets(
    'a focused draft previews, applies once, and undoes as one edit',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = _session();
      final controller = await _pumpComposer(tester, session);
      const original = 'before chosen after';
      final source = await _capture(tester, controller, original);
      expect(source.sourceLabel, 'Chat draft');
      expect(session.models, isNotNull);
      expect(source.sessionModel, session.models!.selected.id);
      expect(source.selectedText, 'chosen');
      expect(source.contextText, 'before \n[selection]\n after');
      expect(source.canApply, isTrue);

      final previousProviders = ModelProviders.current;
      final providers = ModelProviders.memory(
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
        ModelProviders.current = previousProviders;
        providers.dispose();
      });
      await providers.setQuickAskModel('@test/small');
      Map<String, dynamic>? asked;
      final service = QuickAskService(
        providers: providers,
        request: (system, prompt, {model, required exact, cancel}) async {
          asked = jsonDecode(prompt) as Map<String, dynamic>;
          return 'proposed';
        },
      );
      unawaited(
        showQuickAsk(
          tester.element(find.byType(ChatComposer)),
          source: source,
          service: service,
        ),
      );
      await tester.pumpAndSettle();
      expect(asked, isNull);
      await _chooseSecondary(tester, 'Edit selection');
      await tester.enterText(_input('quick-ask-question'), 'Rewrite this');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(asked!['mode'], 'edit');
      expect(asked!['selection'], 'chosen');
      expect(controller.text, original);
      expect(session.itemCount, 0);

      await _chooseSecondary(tester, 'Proposed replacement (editable)');
      await tester.enterText(_input('quick-ask-replacement'), 'reviewed');
      await _chooseSecondary(tester, 'Apply replacement');
      await tester.pumpAndSettle();
      expect(controller.text, 'before reviewed after');
      expect(session.draft.content, controller.text);
      expect(session.itemCount, 0);
      await _openSecondaryMenu(tester);
      expect(
        tester.widget<Semantics>(_menuEntry('Applied').last).properties.enabled,
        isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(await source.applyReplacement!('again'), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(QuickAskDialog), findsNothing);
      expect(
        tester.widget<MarkdownEditor>(_editor()).focusNode!.hasFocus,
        isTrue,
      );
      expect(controller.undo(), isTrue);
      await tester.pump();
      expect(controller.text, original);
      expect(session.draft.content, original);
      expect(controller.redo(), isTrue);
      await tester.pump();
      expect(controller.text, 'before reviewed after');
      expect(controller.undo(), isTrue);
      expect(controller.undo(), isTrue);
      await tester.pump();
      expect(
        controller.text,
        isEmpty,
        reason: 'typing is a separate undo step',
      );
    },
  );

  final embeds = <String, ComposerEmbed>{
    'file mention': ComposerTokenEmbed.file('lib/example.dart'),
    'copied code': ComposerCodeEmbed.of(
      const CodeReference(
        path: 'lib/example.dart',
        start: 3,
        end: 4,
        code: 'private embedded body\nnot selected',
      ),
    ),
    'long paste': ComposerPastedTextEmbed.of(
      const PastedText(number: 1, text: 'private embedded body\nnot selected'),
    ),
    'image reference': ComposerImageEmbed.of(1),
  };
  for (final MapEntry(key: name, value: embed) in embeds.entries) {
    testWidgets('$name captures its label, not its payload, and cannot apply', (
      tester,
    ) async {
      final controller = await _pumpComposer(tester, _session());
      final text = 'before ${embed.atom} after';
      final source = await _capture(
        tester,
        controller,
        text,
        end: 7 + embed.atom.length,
      );
      expect(source.selectedText, embed.plainText);
      expect(source.contextText, 'before \n[selection]\n after');
      expect(source.canApply, isFalse);
      expect(source.applyReplacement, isNull);
      expect(source.selectedText, isNot(contains('private embedded body')));
      expect(source.selectedText, isNot(contains(MdAtoms.open)));
      expect(controller.text, text);

      // Offsets after an atom use its visible label, not its encoded metadata.
      controller.selection = TextSelection(
        baseOffset: text.length,
        extentOffset: text.length - 5,
      );
      await tester.pump();
      final after = QuickAskContext.captureFocused()!;
      expect(after.selectedText, 'after');
      expect(after.contextText, 'before ${embed.plainText} \n[selection]\n');
      expect(after.contextText, isNot(contains('private embedded body')));
      expect(after.contextText, isNot(contains(MdAtoms.open)));
      expect(after.canApply, isTrue);
      expect(await after.applyReplacement!('changed'), isTrue);
      expect(controller.text, 'before ${embed.atom} changed');
      expect(controller.embeds.single.embed, embed);
      expect(controller.undo(), isTrue);
      expect(controller.text, text);
    });
  }

  testWidgets('moving the caret does not retarget the captured replacement', (
    tester,
  ) async {
    final controller = await _pumpComposer(tester, _session());
    final source = await _capture(tester, controller, 'before chosen after');
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    expect(await source.applyReplacement!('changed'), isTrue);
    expect(controller.text, 'before changed after');
  });

  for (final undo in [false, true]) {
    testWidgets(
      'a changed draft${undo ? ', even undone,' : ''} rejects Apply',
      (tester) async {
        final controller = await _pumpComposer(tester, _session());
        final source = await _capture(
          tester,
          controller,
          'before chosen after',
        );
        controller.breakUndo();
        controller.replace(controller.length, controller.length, ' changed');
        if (undo) expect(controller.undo(), isTrue);
        await tester.pump();
        final current = controller.text;
        expect(await source.applyReplacement!('stale'), isFalse);
        expect(controller.text, current);
      },
    );
  }

  testWidgets('a draft updated from another composer rejects captured Apply', (
    tester,
  ) async {
    final session = _session();
    final controller = await _pumpComposer(tester, session);
    final source = await _capture(tester, controller, 'before chosen after');
    session.draft.save(
      'draft edited elsewhere',
      const TextSelection.collapsed(offset: 21),
      const [],
    );
    await tester.pump();
    expect(controller.text, 'draft edited elsewhere');
    expect(await source.applyReplacement!('stale'), isFalse);
    expect(controller.text, 'draft edited elsewhere');
  });

  testWidgets('switching sessions and back invalidates a captured draft', (
    tester,
  ) async {
    final session = _session();
    final other = _session();
    final controller = await _pumpComposer(tester, session);
    final source = await _capture(tester, controller, 'before chosen after');
    final state = tester.state<ChatComposerState>(find.byType(ChatComposer));
    await _pumpComposer(tester, other, draft: session.draft);
    expect(
      QuickAskContext.captureFocused()!.sessionModel,
      other.models!.selected.id,
    );
    await _pumpComposer(tester, session);
    expect(
      tester.state<ChatComposerState>(find.byType(ChatComposer)),
      same(state),
    );
    expect(controller.text, 'before chosen after');
    expect(await source.applyReplacement!('stale'), isFalse);
    expect(controller.text, 'before chosen after');
  });

  testWidgets('switching draft identity and back invalidates captured Apply', (
    tester,
  ) async {
    final session = _session();
    final otherDraft = ComposerDraft();
    addTearDown(otherDraft.dispose);
    final controller = await _pumpComposer(tester, session);
    final source = await _capture(tester, controller, 'before chosen after');
    await _pumpComposer(tester, session, draft: otherDraft);
    await _pumpComposer(tester, session);
    expect(controller.text, 'before chosen after');
    expect(await source.applyReplacement!('stale'), isFalse);
    expect(controller.text, 'before chosen after');
  });

  testWidgets(
    'closing the composer rejects Apply without using its controller',
    (tester) async {
      final controller = await _pumpComposer(tester, _session());
      final source = await _capture(tester, controller, 'before chosen after');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(await source.applyReplacement!('stale'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
