import 'package:flutter/widgets.dart';

import '../ide/ide_find_widget.dart';
import 'chat_find.dart';

/// The find bar over a conversation: the editor's.
class ChatFindBar extends StatelessWidget {
  const ChatFindBar({super.key, required this.find});

  final ChatFind find;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: find,
    builder: (context, _) {
      if (!find.visible) return const SizedBox.shrink();
      return IdeFindWidget(
        findController: find.text,
        findFocusNode: find.focusNode,
        matchCase: find.matchCase,
        wholeWord: find.wholeWord,
        regex: find.regex,
        matchCount: find.matches.length,
        currentIndex: find.current,
        onToggleMatchCase: find.toggleMatchCase,
        onToggleWholeWord: find.toggleWholeWord,
        onToggleRegex: find.toggleRegex,
        onPrevious: find.previous,
        onNext: find.next,
        onClose: find.hide,
      );
    },
  );
}
