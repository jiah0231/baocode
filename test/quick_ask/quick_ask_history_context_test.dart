import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/quick_ask/quick_ask_context.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
