import 'dart:math';

import 'package:baocode/quick_ask/quick_ask_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('independent decisions compose one exact selection replacement', () {
    final diff = QuickAskDiff('first\nsame\nlast\n', 'FIRST\nsame\nLAST\n');
    expect(diff.hunks, hasLength(2));
    expect(diff.hunks.map((h) => h.line), [1, 3]);
    diff.hunks.first.included = false;
    expect(diff.replacement, 'first\nsame\nLAST\n');
    diff.hunks.last.included = false;
    expect(diff.hasChanges, isFalse);
    expect(diff.replacement, diff.original);
    diff.hunks.first.included = true;
    expect(diff.replacement, 'FIRST\nsame\nlast\n');
  });

  for (final pair in [
    ('', 'inserted'),
    ('deleted', ''),
    ('same', 'same'),
    ('line', 'line\n'),
    ('line\n', 'line'),
    ('a\r\nb\r\nc', 'a\r\nB\r\nc'),
    ('中文😀\n', '中文🧑🏽‍💻\n'),
    ('a\nb\n', 'start\na\nb\nend'),
    ('start\na\nb\nend', 'a\nb\n'),
    ('\n\n', '\n'),
  ]) {
    test('preserves exact bytes ${pair.toString()}', () {
      final diff = QuickAskDiff(pair.$1, pair.$2);
      expect(diff.replacement, pair.$2);
      for (final hunk in diff.hunks) {
        hunk.included = false;
      }
      expect(diff.replacement, pair.$1);
    });
  }

  test('bounded fallback does not allocate a quadratic newline-heavy diff', () {
    final diff = QuickAskDiff('a\n' * 4000, 'b\n' * 16000);
    expect(diff.hunks, hasLength(1));
    expect(diff.replacement, diff.proposed);
    diff.hunks.single.included = false;
    expect(diff.replacement, diff.original);
  });

  test('randomized line edits round trip without lost characters', () {
    final random = Random(47);
    const alphabet = ['a\n', 'a\r\n', '\n', '😀\n', 'last'];
    String text() => List.generate(
      random.nextInt(25),
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
    for (var i = 0; i < 500; i++) {
      final diff = QuickAskDiff(text(), text());
      expect(diff.replacement, diff.proposed);
      var end = 0;
      for (final hunk in diff.hunks) {
        expect(hunk.start, greaterThanOrEqualTo(end));
        expect(diff.original.substring(hunk.start, hunk.end), hunk.original);
        end = hunk.end;
        hunk.included = false;
      }
      expect(diff.replacement, diff.original);
    }
  });
}
