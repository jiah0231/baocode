import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/chat/widgets/thinking_section.dart';
import 'package:baocode/theme/app_theme.dart';

class _CountingFeed extends ChangeNotifier implements ChatFeed {
  _CountingFeed({int turns = 0})
    : items = [
        for (var i = 0; i < turns; i++) ...[
          UserMessageItem(text: 'Question $i'),
          AssistantTextItem('Answer $i'),
        ],
        const UserMessageItem(text: 'Current question'),
        const AssistantTextItem('word0'),
      ];

  final List<ChatItem> items;
  int reads = 0;
  bool streaming = true;

  void write(int n) {
    items.last = AssistantTextItem('word$n');
    notifyListeners();
  }

  @override
  int get itemCount => items.length;

  @override
  ChatItem itemAt(int index) {
    reads++;
    return items[index];
  }

  @override
  bool get isStreaming => streaming;

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

Widget _view(_CountingFeed feed) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(body: ChatHistoryView(feed: feed)),
);

Finder _text(String text) => find.text(text, findRichText: true);

void main() {
  testWidgets('waiting word deltas do not rescan a long history', (
    tester,
  ) async {
    final feed = _CountingFeed(turns: 250);
    addTearDown(feed.dispose);
    await tester.pumpWidget(_view(feed));
    await tester.pump(const Duration(seconds: 1));
    feed.write(1);
    await tester.pump();
    feed.reads = 0;

    // No frame or cooldown passes during this burst. Previously each
    // event read all 502 items to rebuild folds, despite hiding its words.
    for (var n = 2; n <= 101; n++) {
      feed.write(n);
    }
    expect(feed.reads, lessThan(2000));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_text('word101'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('merged thoughts refresh when waiting words are shown', (
    tester,
  ) async {
    final feed = _CountingFeed();
    feed.items
      ..removeLast()
      ..addAll([
        const ThinkingItem(text: 'First thought', tokens: 2, seconds: 1),
        const ThinkingItem(text: 'Second thought', tokens: 2),
      ]);
    addTearDown(feed.dispose);
    await tester.pumpWidget(_view(feed));
    await tester.pump(const Duration(seconds: 1));
    void think(String text) {
      feed.items.last = ThinkingItem(text: text, tokens: 3);
      feed.notifyListeners();
    }

    think('Immediate thought');
    await tester.pump();
    think('Latest thought');
    await tester.pump(const Duration(milliseconds: 250));
    final thought = tester.widget<ThinkingSection>(
      find.byType(ThinkingSection),
    );
    expect(thought.text, contains('First thought'));
    expect(thought.text, contains('Latest thought'));
    expect(thought.text, isNot(contains('Immediate thought')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('turn ending flushes words waiting in the throttle', (
    tester,
  ) async {
    final feed = _CountingFeed();
    addTearDown(feed.dispose);
    await tester.pumpWidget(_view(feed));
    await tester.pump(const Duration(seconds: 1));
    feed.write(1);
    await tester.pump();
    feed.write(2);
    feed.streaming = false;
    feed.notifyListeners();
    await tester.pump();
    expect(_text('word2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('switching feeds while words wait uses only the new feed', (
    tester,
  ) async {
    final before = _CountingFeed();
    final after = _CountingFeed()..write(9);
    addTearDown(before.dispose);
    addTearDown(after.dispose);
    await tester.pumpWidget(_view(before));
    await tester.pump(const Duration(seconds: 1));
    before.write(1);
    await tester.pump();
    before.write(2);
    await tester.pumpWidget(_view(after));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_text('word9'), findsOneWidget);
    expect(_text('word2'), findsNothing);
    // An unmounted view must not refold or setState when a cooldown ends.
    after.write(10);
    after.write(11);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
  });
}
