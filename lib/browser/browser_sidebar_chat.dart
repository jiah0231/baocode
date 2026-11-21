import '../chat/chat_models.dart';
import '../chat/chat_session.dart';
import 'sidebar_prose_snapshot.dart';

/// An entry in the local desktop conversation catalog. History is only
/// opened when this entry is selected, not when the list is requested.
class BrowserSidebarThread {
  const BrowserSidebarThread(this.identity, this.readTitle, this.open);
  final Object identity;
  final String Function() readTitle;
  String get title => readTitle();
  final ChatSession? Function() open;
}

/// State for authenticated native-browser connections. Each verified
/// browser window or sidebar document selects its own conversation.
class BrowserSidebarChat {
  final _sources = <Object, Iterable<BrowserSidebarThread> Function()>{};
  final _ids = Expando<String>();
  final _links = <Object, Map<int, _Grant>>{};
  int _nextId = 0;

  void register(Object owner, Iterable<BrowserSidebarThread> Function() read) {
    _sources[owner] = read;
  }

  void unregister(Object owner) => _sources.remove(owner);

  Iterable<BrowserSidebarThread> _threads() sync* {
    final seen = Set<Object>.identity();
    for (final read in _sources.values) {
      for (final entry in read()) {
        if (seen.add(entry.identity)) yield entry;
      }
    }
  }

  String _id(BrowserSidebarThread entry) =>
      _ids[entry.identity] ??= (++_nextId).toString();

  void disconnect(Object connection) {
    _links.remove(connection);
  }

  void revoke() => _links.clear();

  Map<String, Object?> handle(Object connection, Map<String, Object?> request) {
    final window = request['windowId'];
    if (window is! int || window < 0) return const {'error': 'invalid'};
    final action = request['action'];
    if (action == 'list') {
      final offset = request['offset'];
      final query = request['query'];
      if (offset is! int || offset < 0 || offset > 1000000 ||
          query is! String || query.length > 100) {
        return const {'error': 'invalid'};
      }
      final key = query.trim().toLowerCase();
      final page = _threads()
          .where((entry) => entry.title.toLowerCase().contains(key))
          .skip(offset)
          .take(51)
          .toList();
      return {
        'threads': [
          for (final entry in page.take(50))
            {'id': _id(entry), 'title': _limit(entry.title, 160)},
        ],
        'more': page.length > 50,
      };
    }
    if (action == 'select') {
      final id = request['threadId'];
      if (id is! String || id.isEmpty || id.length > 20) {
        return const {'error': 'invalid'};
      }
      BrowserSidebarThread? target;
      for (final entry in _threads()) {
        if (_ids[entry.identity] == id) {
          target = entry;
          break;
        }
      }
      if (target == null) return const {'error': 'missing'};
      final session = target.open();
      if (session == null) return const {'error': 'missing'};
      final entry = target;
      final windows = _links.putIfAbsent(connection, () => {});
      if (windows.length >= 16 && !windows.containsKey(window)) {
        windows.remove(windows.keys.first);
      }
      windows[window] = _Grant(
        () => identical(entry.open(), session) ? session : null,
        () => entry.title,
      );
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

    final items = sidebarProseTail(session.itemCount, session.itemAt);
    return {
      'linked': true,
      'title': _limit(grant.title(), 160),
      'ready': _ready(session),
      'running': session.isStreaming,
      'approval': session.pendingInteraction != null,
      'items': [for (final row in items) row.toWire()],
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
