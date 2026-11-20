// Compile the real message rows, at a side panel width, with synthetic data.
import 'package:baocode/chat/chat_column.dart';
import 'package:baocode/chat/chat_feed_contract.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/chat/composer/composer_message.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/chat/widgets/chat_item_view.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

void main() {
  final feed = _FixtureFeed();
  runApp(MaterialApp(
    title: 'BaoCode chat contract probe',
    theme: buildAppTheme(),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 380,
          child: ChatColumn(
            maxWidth: 680,
            child: ListView.builder(
              itemCount: feed.itemCount,
              itemBuilder: (context, row) => ChatItemView(
                item: feed.itemAt(row),
                expanded: true,
              ),
            ),
          ),
        ),
      ),
    ),
  ));
}

class _FixtureFeed extends ChangeNotifier implements ChatFeed {
  final _items = <ChatItem>[
    UserMessageItem(text: 'Synthetic user message'),
    const AssistantTextItem('**Synthetic reply** with `inline code`.'),
    const ToolCallItem(
      kind: ToolKind.other,
      target: 'Synthetic tool',
      output: 'Synthetic tool output',
    ),
  ].map((item) => ChatCodec.decode(ChatCodec.encode(item))!).toList();

  @override
  int get itemCount => _items.length;
  @override
  ChatItem itemAt(int index) => _items[index];
  @override
  bool get isStreaming => false;
  @override
  bool get isUnprompted => false;
  @override
  bool get canEditMessages => false;
  @override
  ({int index, ComposerDraft draft})? editing;
  @override
  void editMessage(int index, ComposerMessage message, {UserPlace? from}) {}
  @override
  VoidCallback? moveToBackgroundAt(int index) => null;
  @override
  VoidCallback? stopAt(int index) => null;
}
