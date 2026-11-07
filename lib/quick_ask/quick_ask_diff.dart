import 'dart:typed_data';

/// An exact, line-based selection review. Decisions are staged, not written to
/// the editor: applying the composed result remains one revision-checked edit.
class QuickAskDiff {
  QuickAskDiff(this.original, this.proposed) {
    final before = _lines(original);
    final after = _lines(proposed);
    var first = 0;
    while (first < before.length &&
        first < after.length &&
        before[first] == after[first]) {
      first++;
    }
    var oldEnd = before.length;
    var newEnd = after.length;
    while (oldEnd > first &&
        newEnd > first &&
        before[oldEnd - 1] == after[newEnd - 1]) {
      oldEnd--;
      newEnd--;
    }
    final offsets = [0];
    for (final line in before) {
      offsets.add(offsets.last + line.length);
    }
    void add(int start, int end, int from, int to) {
      if (start == end && from == to) return;
      hunks.add(
        QuickAskHunk(
          start: offsets[start],
          end: offsets[end],
          line: start + 1,
          original: before.sublist(start, end).join(),
          proposed: after.sublist(from, to).join(),
        ),
      );
    }

    final rows = oldEnd - first;
    final columns = newEnd - first;
    // Newline-heavy output must not allocate a quadratic table or stall input.
    // The fallback is still an exact and independently reviewable replacement.
    if (rows == 0 || columns == 0 || rows * columns > 250000) {
      add(first, oldEnd, first, newEnd);
      return;
    }
    final table = List.generate(rows + 1, (_) => Uint32List(columns + 1));
    for (var i = rows - 1; i >= 0; i--) {
      for (var j = columns - 1; j >= 0; j--) {
        table[i][j] = before[first + i] == after[first + j]
            ? table[i + 1][j + 1] + 1
            : (table[i + 1][j] > table[i][j + 1]
                  ? table[i + 1][j]
                  : table[i][j + 1]);
      }
    }
    var i = 0;
    var j = 0;
    var start = 0;
    var from = 0;
    while (i < rows || j < columns) {
      if (i < rows && j < columns && before[first + i] == after[first + j]) {
        add(first + start, first + i, first + from, first + j);
        i++;
        j++;
        start = i;
        from = j;
      } else if (j < columns &&
          (i == rows || table[i][j + 1] > table[i + 1][j])) {
        j++;
      } else {
        i++;
      }
    }
    add(first + start, oldEnd, first + from, newEnd);
  }

  final String original;
  final String proposed;
  final List<QuickAskHunk> hunks = [];

  bool get hasChanges => hunks.any((hunk) => hunk.included);

  String get replacement {
    final result = StringBuffer();
    var end = 0;
    for (final hunk in hunks) {
      result.write(original.substring(end, hunk.start));
      result.write(hunk.included ? hunk.proposed : hunk.original);
      end = hunk.end;
    }
    return (result..write(original.substring(end))).toString();
  }

  // Keep terminators, including CRLF and missing final LF, byte-for-byte.
  static List<String> _lines(String text) => [
    for (final match in RegExp(r'[^\n]*\n|[^\n]+$').allMatches(text))
      match.group(0)!,
  ];
}

class QuickAskHunk {
  QuickAskHunk({
    required this.start,
    required this.end,
    required this.line,
    required this.original,
    required this.proposed,
  });

  final int start;
  final int end;
  final int line;
  final String original;
  final String proposed;
  bool included = true;
}
