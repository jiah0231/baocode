import 'package:baocode/browser/sidebar_frame_budget.dart';
import 'package:baocode/browser/sidebar_prose_snapshot.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sidebar prose filters non-conversation content and preserves Markdown', () {
    const items = <ChatItem>[
      UserMessageItem(text: '中文🙂'),
      ThinkingItem(text: 'hidden thinking', tokens: 2),
      UserMessageItem(text: 'hidden from another session', fromSession: 'other'),
      UserMessageItem(text: 'hidden from an agent', fromAgent: 'agent'),
      AssistantTextItem('**Answer** with `code`.'),
      AssistantTextItem(''),
    ];
    final rows = sidebarProseTail(items.length, (i) => items[i]);
    expect(rows.map((r) => r.toWire()), [
      {'role': 'user', 'text': '中文🙂'},
      {'role': 'assistant', 'text': '**Answer** with `code`.'},
    ]);
    for (final row in rows) {
      final decoded = SidebarProseRow.fromWire(row.toWire());
      expect(decoded?.role, row.role);
      expect(decoded?.text, row.text);
    }
  });

  test('scan and eligible rows are bounded independently', () {
    final items = <ChatItem>[
      const UserMessageItem(text: 'outside scan'),
      for (var i = 0; i < 300; i++)
        const ThinkingItem(text: 'omitted', tokens: 1),
      for (var i = 0; i < 30; i++) AssistantTextItem('row $i'),
    ];
    var reads = 0;
    final rows = sidebarProseTail(items.length, (i) {
      reads++;
      return items[i];
    });
    expect(reads, 24);
    expect(rows.map((row) => row.text), List.generate(24, (i) => 'row ${i + 6}'));
    var onlyHiddenReads = 0;
    expect(sidebarProseTail(301, (i) {
      onlyHiddenReads++;
      return items[i];
    }), isEmpty);
    expect(onlyHiddenReads, 256);
  });

  test('oversized rows do not split emoji and remain under the frame budget', () {
    final prefix = List.filled(3999, 'a').join();
    final row = sidebarProseTail(1, (_) => AssistantTextItem('${prefix}🙂tail')).single;
    expect(row.text, '${prefix}…');
    final escaped = List.filled(4000, '\u0001').join();
    final rows = sidebarProseTail(24, (_) => UserMessageItem(text: escaped));
    final encoded = encodeSidebarResult('request', {
      'items': [for (final row in rows) row.toWire()],
    });
    expect(encoded.length, greaterThan(24 * 4000));
    expect(encoded.length, lessThanOrEqualTo(sidebarResultMaxBytes));
  });

  test('unknown roles, missing rows and oversized text fail decode', () {
    expect(SidebarProseRow.fromWire([]), isNull);
    expect(SidebarProseRow.fromWire({'role': 'tool', 'text': 'x'}), isNull);
    expect(SidebarProseRow.fromWire({'role': 'assistant', 'text': ''}), isNull);
    expect(SidebarProseRow.fromWire({
      'role': 'user', 'text': List.filled(4002, 'x').join(),
    }), isNull);
  });
}
