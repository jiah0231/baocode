import 'dart:math';

import '../chat/chat_models.dart';
import '../chat/chat_session.dart';

/// A one-use invitation to an explicitly chosen conversation. Only the
/// claiming browser connection and window can use it.
class BrowserSidebarChat {
  final _random = Random.secure();
  ({String code, DateTime expires, _Grant grant})? _invitation;
  final _links = <Object, Map<int, _Grant>>{};

  String invite(ChatSession? Function() session, String Function() title) {
    const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
    final code = List.generate(
      10,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
    _invitation = (
      code: code,
      expires: DateTime.now().add(const Duration(minutes: 2)),
      grant: _Grant(session, title),
    );
    return code;
  }

  void disconnect(Object connection) {
    _links.remove(connection);
  }

  void revoke() {
    _invitation = null;
    _links.clear();
  }

  Map<String, Object?> handle(Object connection, Map<String, Object?> request) {
    final window = request['windowId'];
    if (window is! int || window < 0) return const {'error': 'invalid'};
    final action = request['action'];
    if (action == 'claim') {
      final pending = _invitation;
      if (pending == null ||
          !DateTime.now().isBefore(pending.expires) ||
          pending.code != request['code'] ||
          pending.grant.session() == null) {
        return const {'error': 'code'};
      }
      _invitation = null;
      final windows = _links.putIfAbsent(connection, () => {});
      if (windows.length >= 16 && !windows.containsKey(window)) {
        windows.remove(windows.keys.first);
      }
      windows[window] = pending.grant;
    } else if (action == 'unlink') {
      _links[connection]?.remove(window);
      return const {'linked': false};
    } else if (action != 'snapshot' && action != 'send') {
      return const {'error': 'invalid'};
    }

    final grant = _links[connection]?[window];
    final session = grant?.session();
    if (grant == null || session == null) {
      _links[connection]?.remove(window);
      return const {'linked': false};
    }
    if (action == 'send') {
      final id = request['messageId'];
      final raw = request['text'];
      if (id is! String ||
          id.length > 80 ||
          id.isEmpty ||
          raw is! String ||
          raw.length > 8000 ||
          raw.trim().isEmpty) {
        return const {'error': 'invalid'};
      }
      if (!grant.sent.contains(id)) {
        if (!_ready(session)) return const {'error': 'busy'};
        session.send(ComposerMessage(text: raw.trim()));
        grant.sent.add(id);
        if (grant.sent.length > 128) grant.sent.remove(grant.sent.first);
      }
      return const {'linked': true};
    }

    // Cap JSON below 1 MiB even when every UTF-16 code unit is escaped.
    // Only top-level user-visible text; no tools, thoughts or image bytes.
    final items = <Map<String, Object?>>[];
    final count = session.itemCount;
    for (
      var i = count - 1;
      i >= 0 && i >= count - 256 && items.length < 24;
      i--
    ) {
      final (role, body) = switch (session.itemAt(i)) {
        UserMessageItem(:final text, fromAgent: null, fromSession: null) =>
          ('user', text),
        AssistantTextItem(:final text) => ('assistant', text),
        _ => ('', ''),
      };
      if (body.isNotEmpty) items.add({'role': role, 'text': _limit(body, 4000)});
    }
    return {
      'linked': true,
      'title': _limit(grant.title(), 160),
      'ready': _ready(session),
      'running': session.isStreaming,
      'approval': session.pendingInteraction != null,
      'items': items.reversed.toList(),
    };
  }

  static bool _ready(ChatSession session) =>
      !session.isStreaming &&
      session.pendingInteraction == null &&
      session.canSend;

  static String _limit(String text, int max) {
    if (text.length <= max) return text;
    final end = text.codeUnitAt(max - 1);
    final safe = end >= 0xd800 && end <= 0xdbff ? max - 1 : max;
    return '${text.substring(0, safe)}…';
  }
}

class _Grant {
  _Grant(this.session, this.title);
  final ChatSession? Function() session;
  final String Function() title;
  final sent = <String>{};
}
