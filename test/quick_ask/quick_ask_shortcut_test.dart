import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/keybindings/keybinding_service.dart';
import 'package:baocode/quick_ask/quick_ask_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workspace/chat_window_keys_test.dart' as window;

void main() {
  setUp(() => KeybindingService.instance = KeybindingService());
  tearDown(() => KeybindingService.instance = KeybindingService());

  testWidgets(
    'agent shortcut captures selection, opens once, and restores focus',
    (tester) async {
      final workspace = await window.pumpApp(tester);
      await window.press(tester, LogicalKeyboardKey.keyN, control: true);
      final thread = workspace.current!;
      expect(window.inputFocused(tester, thread), isTrue);
      final editor = tester.widget<MarkdownEditor>(
        find
            .descendant(
              of: find.byWidgetPredicate(
                (widget) =>
                    widget is ChatScreen &&
                    identical(widget.session, thread.session),
              ),
              matching: find.byType(MarkdownEditor),
            )
            .first,
      );
      editor.controller.text = 'before chosen after';
      editor.controller.selection = const TextSelection(
        baseOffset: 7,
        extentOffset: 13,
      );
      await tester.pump();
      await window.press(
        tester,
        LogicalKeyboardKey.keyK,
        control: true,
        alt: true,
      );
      expect(find.byType(QuickAskDialog), findsOneWidget);
      final dialog = tester.widget<QuickAskDialog>(find.byType(QuickAskDialog));
      expect(dialog.source?.selectedText, 'chosen');
      expect(dialog.source?.canApply, isTrue);
      await window.press(
        tester,
        LogicalKeyboardKey.keyK,
        control: true,
        alt: true,
      );
      expect(find.byType(QuickAskDialog), findsOneWidget);
      await window.press(tester, LogicalKeyboardKey.escape);
      expect(find.byType(QuickAskDialog), findsNothing);
      expect(window.inputFocused(tester, thread), isTrue);
      expect(editor.controller.text, 'before chosen after');
      await window.press(
        tester,
        LogicalKeyboardKey.keyK,
        control: true,
        alt: true,
      );
      expect(find.byType(QuickAskDialog), findsOneWidget);
    },
  );
}
