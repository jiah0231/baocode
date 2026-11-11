import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/step_folds.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/transcript.dart';

void main() {
  test('text rows accumulate for independent throttled observers', () {
    final t = Transcript()
      ..apply(const ItemUpserted(1, 'a', AssistantTextItem('a')))
      ..apply(const ItemUpserted(2, 'b', ThinkingItem(text: 'b', tokens: 0)));
    final revision = t.structureVersion;
    t.apply(const TextDelta(3, 'a', 1, 'A'));
    expect(t.textChangedRows, {0});
    t.apply(const TextDelta(4, 'b', 1, 'B'));
    expect(t.textChangedRows, {0, 1});
    t.apply(const TextDelta(5, 'a', 2, 'C'));
    expect(t.textChangedRows, {0, 1});
    expect(t.structureVersion, revision);
    expect(t.apply(const TextDelta(5, 'b', 2, 'ignored')), isFalse);
    expect(t.apply(const TextDelta(6, 'missing', 0, 'ignored')), isFalse);
    expect(t.structureVersion, revision);
    expect(t.textChangedRows, {0, 1});
    t.apply(const UsageReported(7, ContextUsage(window: 1000, used: 400)));
    expect(t.structureVersion, revision);
    expect(t.textChangedRows, {0, 1});
    t.apply(
      const ItemCompleted(
        8,
        'b',
        item: ThinkingItem(text: 'done', tokens: 2, seconds: 1),
      ),
    );
    expect(t.structureVersion, greaterThan(revision));
    expect(t.textChangedRows, isEmpty);
  });

  test('structural changes reset row indexes, even same-count replacement', () {
    final t = Transcript()
      ..apply(const ItemUpserted(1, 'a', AssistantTextItem('a')))
      ..apply(const TextDelta(2, 'a', 1, 'A'));
    var revision = t.structureVersion;
    t.apply(const ItemUpserted(3, 'a', UserMessageItem(text: 'changed kind')));
    expect(t.structureVersion, greaterThan(revision));
    expect(t.textChangedRows, isEmpty);
    revision = t.structureVersion;
    t.apply(const HistoryPrepended(4, [('old', AssistantTextItem('old'))]));
    expect(t.structureVersion, greaterThan(revision));
    t.apply(const TextDelta(5, 'old', 3, 'X'));
    expect(t.textChangedRows, {0});
    revision = t.structureVersion;
    t.apply(const ItemRemoved(6, 'old'));
    expect(t.structureVersion, greaterThan(revision));
    expect(t.textChangedRows, isEmpty);
    revision = t.structureVersion;
    t.apply(const Rewound(7, index: 0));
    expect(t.structureVersion, greaterThan(revision));
    expect(t.length, 0);
  });

  test('refreshing a later thought invalidates its merged first row', () {
    final items = <ChatItem>[
      const UserMessageItem(text: 'Question'),
      const ThinkingItem(text: 'First', tokens: 1),
      const ThinkingItem(text: 'Second', tokens: 1),
    ];
    final folds = StepFolds.of(items.length, (i) => items[i], live: true);
    expect(
      (folds.shownAt(1, items[1]) as ThinkingItem).text,
      'First\n\nSecond',
    );
    items[2] = const ThinkingItem(text: 'Second updated', tokens: 2);
    expect(folds.refreshText([2], (i) => items[i]), 1);
    expect(
      (folds.shownAt(1, items[1]) as ThinkingItem).text,
      'First\n\nSecond updated',
    );
    expect((folds.shownAt(1, items[1]) as ThinkingItem).tokens, 3);
    expect(folds.rowAt(2, items[2], (_) => false).item, isFalse);
  });
}
