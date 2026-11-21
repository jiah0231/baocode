import '../chat/chat_models.dart';

const _scanLimit = 256;
const _rowLimit = 24;
const _textLimit = 4000;

enum SidebarProseRole { user, assistant }

/// Shared decode boundary for the existing sidebar snapshot's prose rows.
/// The browser never receives full ChatItem metadata through this adapter.
class SidebarProseRow {
  const SidebarProseRow(this.role, this.text);

  final SidebarProseRole role;
  final String text;

  static SidebarProseRow? fromWire(Object? value) {
    if (value is! Map) return null;
    final text = value['text'];
    if (text is! String || text.isEmpty || text.length > _textLimit + 1) {
      return null;
    }
    return switch (value['role']) {
      'user' => SidebarProseRow(SidebarProseRole.user, text),
      'assistant' => SidebarProseRow(SidebarProseRole.assistant, text),
      _ => null,
    };
  }

  Map<String, Object?> toWire() => {'role': role.name, 'text': text};
}

/// Read only the selected session's visible top-level prose. Keep the
/// legacy response size/shape unchanged until history paging is versioned.
List<SidebarProseRow> sidebarProseTail(
  int itemCount,
  ChatItem Function(int index) itemAt,
) {
  final rows = <SidebarProseRow>[];
  for (
    var i = itemCount - 1;
    i >= 0 && i >= itemCount - _scanLimit && rows.length < _rowLimit;
    i--
  ) {
    final (role, text) = switch (itemAt(i)) {
      UserMessageItem(:final text, fromAgent: null, fromSession: null) =>
        (SidebarProseRole.user, text),
      AssistantTextItem(:final text) => (SidebarProseRole.assistant, text),
      _ => (null, ''),
    };
    if (role != null && text.isNotEmpty) {
      rows.add(SidebarProseRow(role, _boundedText(text)));
    }
  }
  return rows.reversed.toList();
}

String _boundedText(String text) {
  if (text.length <= _textLimit) return text;
  final last = text.codeUnitAt(_textLimit - 1);
  final end = last >= 0xd800 && last <= 0xdbff ? _textLimit - 1 : _textLimit;
  return '${text.substring(0, end)}…';
}
