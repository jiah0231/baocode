import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/quick_ask/quick_ask_context.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

class _Session extends ChatSession {
  _Session() : super(kernel: MockKernels.claudeCode, historyCount: 0);

  String selectedModel = '@session/chat';

  @override
  KernelChoice get models {
    final option = KernelOption(selectedModel, 'Chat model', Icons.code, '');
    return KernelChoice(
      options: [option],
      selected: option,
      onSelected: (_) {},
    );
  }

  @override
  int get itemCount => 1;

  @override
  ChatItem itemAt(int index) => const AssistantTextItem('Visible answer.');

  @override
  bool get isStreaming => false;
}

void main() {
  testWidgets('chat anchor retains rendered selection end after focus clears', (
    tester,
  ) async {
    final session = _Session();
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: ChatHistoryView(key: key, feed: session),
        ),
      ),
    );
    await tester.pumpAndSettle();
    ChatHistoryView.focus(key);
    await tester.pump();
    final container = tester
        .widgetList<SelectionContainer>(
          find.ancestor(
            of: find.byType(SuperListView),
            matching: find.byType(SelectionContainer),
          ),
        )
        .firstWhere(
          (widget) => widget.delegate is StaticSelectionContainerDelegate,
        );
    final delegate =
        container.delegate! as MultiSelectableSelectionContainerDelegate;
    delegate.dispatchSelectionEvent(const SelectAllSelectionEvent());
    await tester.pump();
    final source = QuickAskContext.captureFocused()!;
    final selectable = delegate.selectables.lastWhere(
      (selectable) => selectable.value.endSelectionPoint != null,
    );
    final point = selectable.value.endSelectionPoint!;
    final expected = MatrixUtils.transformRect(
      selectable.getTransformTo(null),
      Rect.fromLTWH(
        point.localPosition.dx,
        point.localPosition.dy - point.lineHeight,
        1,
        point.lineHeight,
      ),
    );
    expect(source.selectionAnchor!(), expected);
    FocusManager.instance.primaryFocus!.unfocus();
    delegate.dispatchSelectionEvent(const ClearSelectionEvent());
    await tester.pump();
    expect(source.selectionAnchor!(), expected);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    expect(source.selectionAnchor!(), isNull);
    session.dispose();
  });

  for (final subagent in [false, true]) {
    testWidgets(
      'captures ${subagent ? 'subagent parent' : 'history'} session model without keeping a live route',
      (tester) async {
        final session = _Session();
        final ChatFeed feed = subagent
            ? SubagentFeed(session, ['worker'])
            : session;
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: ChatHistoryView(key: key, feed: feed),
            ),
          ),
        );
        await tester.pumpAndSettle();
        ChatHistoryView.focus(key);
        await tester.pump();
        final first = QuickAskContext.captureFocused()!;
        expect(first.sessionModel, '@session/chat');
        expect(first.contextText.length, lessThanOrEqualTo(4000));
        expect(first.applyReplacement, isNull);
        session.selectedModel = '@session/other';
        expect(
          QuickAskContext.captureFocused()!.sessionModel,
          '@session/other',
        );
        expect(first.sessionModel, '@session/chat');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 500));
        if (feed is SubagentFeed) feed.dispose();
        session.dispose();
      },
    );
  }
}
