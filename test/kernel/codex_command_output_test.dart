import 'package:baocode/kernel/codex/codex_command_output.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a burst publishes once and retains every delta', (tester) async {
    final snapshots = <String>[];
    late CodexCommandOutput output;
    output = CodexCommandOutput(onChanged: () => snapshots.add(output.text));
    for (var i = 0; i < 10000; i++) {
      output.add('x');
    }
    expect(snapshots, ['x']);
    expect(output.text, 'x' * 10000);
    await tester.pump(const Duration(milliseconds: 65));
    expect(snapshots, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(snapshots, ['x', 'x' * 10000]);
    await tester.pump(const Duration(milliseconds: 66));
    expect(snapshots, hasLength(2));
    output.close();
  });

  testWidgets('completion cancels a pending running snapshot without loss', (
    tester,
  ) async {
    var published = 0;
    final output = CodexCommandOutput(onChanged: () => published++);
    output.add('first');
    output.add(' final tail');
    output.close();
    expect(output.text, 'first final tail');
    await tester.pump(const Duration(seconds: 1));
    expect(published, 1);
    output.add('late');
    expect(output.text, 'first final tail');
  });

  testWidgets('search parsing matches full output at every chunk boundary', (
    tester,
  ) async {
    final output = CodexCommandOutput(onChanged: () {}, search: true);
    const text = '\na.dart:1:match\r\nplain\n:b:c\n::\n終.dart:9:😀\nlast';
    var prefix = '';
    // Deliberately split between CR/LF, colon fields and UTF-16 surrogates.
    for (final unit in text.codeUnits) {
      final delta = String.fromCharCode(unit);
      prefix += delta;
      output.add(delta);
      expect(output.matches, [
        for (final line in prefix.split('\n'))
          if (line.isNotEmpty) line.split(':').take(2).join(':'),
      ]);
    }
    expect(output.text, text);
    final snapshot = output.matches;
    output.add(' tail\n');
    expect(snapshot.last, 'last');
    expect(output.matches.last, 'last tail');
    output.close();
  });

  testWidgets('reentrant completion does not leave a timer', (tester) async {
    late CodexCommandOutput output;
    var calls = 0;
    output = CodexCommandOutput(onChanged: () {
      calls++;
      output.close();
    });
    output.add('done');
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
  });
}
