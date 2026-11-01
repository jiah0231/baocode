import 'dart:async';

import '../../remote/remote_codex.dart';
import '../../remote/remote_location.dart';
import '../agent_kernel.dart';
import 'codex_transport.dart';

/// The conversations Codex keeps (`thread/list`), read from a short-lived
/// `codex app-server`: no process stays up for the list. A remote project's
/// are read on its host, where Codex keeps them.
class CodexCatalog implements SessionCatalog {
  const CodexCatalog({this.startServer = startCodexCatalogServerFor});

  /// Injectable for catalog tests; production uses the local or SSH host.
  final Future<CodexTransport> Function(String? location) startServer;

  /// Where each session listed was found, to delete it there.
  static final Map<String, String> _locationOf = {};

  @override
  Future<List<ProjectRecord>> projects() => _withServer(null, (server) async {
    final sessions = await _list(server);
    for (final session in sessions) {
      _locationOf[session.id] = session.cwd;
    }
    final byCwd = <String, List<SessionRecord>>{};
    for (final session in sessions) {
      if (session.cwd.isEmpty) continue;
      (byCwd[session.cwd] ??= []).add(session);
    }
    final projects = [
      for (final MapEntry(:key, :value) in byCwd.entries)
        ProjectRecord(path: key, sessions: value..sort(_newestFirst)),
    ];
    projects.sort((a, b) {
      final left = a.updatedAt;
      final right = b.updatedAt;
      if (left == null) return right == null ? 0 : 1;
      if (right == null) return -1;
      return right.compareTo(left);
    });
    return projects;
  }, const []);

  @override
  Future<List<SessionRecord>> sessionsIn(String location) =>
      _withServer(location, (server) async {
        final host = RemoteLocation.hostOf(location);
        final path = RemoteLocation.pathOf(location);
        final sessions = await _list(server, cwd: path, host: host);
        for (final session in sessions) {
          _locationOf[session.id] = session.cwd;
        }
        return sessions..sort(_newestFirst);
      }, const []);

  @override
  Future<void> delete(String id) async {
    final location = _locationOf[id];
    await _withServer(location, (server) async {
      await server.request('thread/delete', {'threadId': id});
      _locationOf.remove(id);
      return true;
    }, false);
  }

  static int _newestFirst(SessionRecord a, SessionRecord b) =>
      b.updatedAt.compareTo(a.updatedAt);

  static Future<List<SessionRecord>> _list(
    _Server server, {
    String? cwd,
    String? host,
  }) async {
    final sessions = <SessionRecord>[];
    String? cursor;
    final cursors = <String>{};
    final ids = <String>{};
    while (true) {
      final result = await server.request('thread/list', {
        if (cwd != null) 'cwd': cwd,
        // Every provider's, not the default one's alone: a thread on one
        // of BaoCode's models is kept with its provider ([modelRef]).
        'modelProviders': <String>[],
        'limit': 100,
        if (cursor != null) 'cursor': cursor,
      });
      for (final raw in result['data'] as List? ?? const []) {
        if (raw is! Map) continue;
        if (raw['ephemeral'] == true) continue;
        // Only what BaoCode itself began: Codex keeps its CLI's threads and
        // other apps' in the same list, which are not this app's history.
        if (raw['originator'] != 'baocode') continue;
        final id = raw['id'] as String?;
        if (id == null || !ids.add(id)) continue;
        // What its host keeps it under, as a location.
        final at = raw['cwd'] as String? ?? cwd ?? '';
        sessions.add(
          SessionRecord(
            id: id,
            title: _title(raw),
            updatedAt:
                _time(raw['updatedAt']) ??
                DateTime.fromMillisecondsSinceEpoch(0),
            cwd: RemoteLocation.of(host, at),
            path: raw['path'] as String?,
          ),
        );
      }
      final next = result['nextCursor'] as String?;
      if (next == null || next.isEmpty || !cursors.add(next)) break;
      cursor = next;
    }
    return sessions;
  }

  /// What it is called: its name, else the start of its first message.
  static String _title(Map raw) {
    final name = (raw['name'] as String? ?? '').trim();
    // The server's own until the conversation is named: not a title.
    if (name.isNotEmpty && name != 'Untitled' && name != 'Untitled message') {
      return name;
    }
    final preview = raw['preview'] as String? ?? '';
    final line = preview.split('\n').first.trim();
    if (line.length <= 80) return line;
    return '${line.substring(0, 79).trimRight()}…';
  }

  static DateTime? _time(Object? raw) {
    if (raw is! num) return null;
    final value = raw.toInt();
    if (value <= 0) return null;
    return value < 100000000000
        ? DateTime.fromMillisecondsSinceEpoch(value * 1000)
        : DateTime.fromMillisecondsSinceEpoch(value);
  }

  Future<T> _withServer<T>(
    String? location,
    Future<T> Function(_Server server) body,
    T empty,
  ) async {
    final CodexTransport transport;
    try {
      transport = await startServer(location);
    } on CodexUnavailable {
      // Nothing to list where Codex cannot run (the web).
      return empty;
    }
    final server = _Server(transport);
    try {
      await server.request('initialize', {
        'clientInfo': {'name': 'baocode', 'version': '1.0.0'},
      });
      return await body(server);
    } on CodexUnavailable {
      // A Codex that will not answer has no sessions to show.
      return empty;
    } finally {
      await server.close();
    }
  }
}

/// One short-lived app-server, asked and closed.
class _Server {
  _Server(this._transport) {
    _subscription = _transport.messages.listen(_receive);
    unawaited(_transport.exited.then((_) => _exited()));
  }

  final CodexTransport _transport;
  late final StreamSubscription<Map<String, Object?>> _subscription;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  int _requests = 0;
  bool _closed = false;

  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final id = ++_requests;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _transport.write({'id': id, 'method': method, 'params': params});
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw const CodexUnavailable('Codex did not answer');
      },
    );
  }

  void _receive(Map<String, Object?> message) {
    if (CodexExit.isExit(message)) {
      _exited();
      return;
    }
    if (message['method'] != null) return;
    final completer = _pending.remove(message['id']);
    if (completer == null) return;
    if (message['error'] case final Map error) {
      completer.completeError(
        CodexUnavailable(error['message'] as String? ?? 'Codex request failed'),
      );
    } else {
      completer.complete(
        (message['result'] as Map?)?.cast<String, Object?>() ?? const {},
      );
    }
  }

  void _exited() {
    if (_closed) return;
    _closed = true;
    final error = const CodexUnavailable('Codex stopped');
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<void> close() async {
    await _subscription.cancel();
    _transport.close();
    try {
      await _transport.exited.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // It is ended anyway; nothing of it lingers.
    }
    _exited();
  }
}
