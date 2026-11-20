// Internal Web compile probe with synthetic data. Not an extension or backend.
import 'package:baocode/chat/chat_column.dart';
import 'package:baocode/chat/chat_feed_contract.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/chat/composer/composer_message.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:flutter/material.dart';

void main() {
  final feed = _FixtureFeed();
  runApp(MaterialApp(
    title: 'BaoCode chat contract probe',
    home: Scaffold(
      body: ChatColumn(
        maxWidth: 680,
        child: ListView.builder(
          itemCount: feed.itemCount,
          itemBuilder: (context, row) => Text(switch (feed.itemAt(row)) {
            UserMessageItem(:final text) => text,
            AssistantTextItem(:final text) => text,
            _ => '',
          }),
        ),
      ),
    ),
  ));
}

class _FixtureFeed extends ChangeNotifier implements ChatFeed {
  final _items = <ChatItem>[
    UserMessageItem(text: 'Synthetic user message'),
    const AssistantTextItem('Synthetic reply, same desktop model'),
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
