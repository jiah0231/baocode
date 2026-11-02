import 'dart:async';

import '../../remote/remote_codex.dart';
import '../../remote/remote_location.dart';
import '../agent_kernel.dart';
import 'codex_transport.dart';
import 'codex_session_locations.dart';

/// The conversations Codex keeps (`thread/list`), read from a short-lived
/// `codex app-server`: no process stays up for the list. A remote project's
/// are read on its host, where Codex keeps them.
class CodexCatalog implements SessionCatalog, MovesSessions, SessionHistoryCatalog {
  const CodexCatalog({
    this.startServer = startCodexCatalogServerFor,
    this.locations,
  });

  final CodexSessionLocations? locations;
  CodexSessionLocations get _locations =>
      locations ?? CodexSessionLocations.current;

  /// Injectable for catalog tests; production uses the local or SSH host.
  final Future<CodexTransport> Function(String? location) startServer;

  /// Where each session listed was found, to delete it there.
  static final Map<String, String> _locationOf = {};

  @override
  Future<List<ProjectRecord>> projects() => _withServer(null, (server) async {
    final aliases = await _locations.snapshot();
    final sessions = [
      for (final session in await _list(server))
        CodexSessionLocations.apply(aliases, session),
    ];
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
      _sessionsIn(location);

  Future<List<SessionRecord>> _sessionsIn(
    String location, {
    bool strict = false,
  }) => _withServer(
    location,
    (server) async {
      final host = RemoteLocation.hostOf(location);
      final aliases = await _locations.snapshot();
      final byId = <String, SessionRecord>{};
      for (final source in CodexSessionLocations.sources(aliases, location)) {
        for (final raw in await _list(
          server,
          cwd: RemoteLocation.pathOf(source),
          host: host,
        )) {
          final session = CodexSessionLocations.apply(aliases, raw);
          if (CodexSessionLocations.sameLocation(session.cwd, location)) {
            byId[session.id] = session;
          }
        }
      }
      final sessions = byId.values.toList();
      for (final session in sessions) {
        _locationOf[session.id] = session.cwd;
      }
      return sessions..sort(_newestFirst);
    },
    const [],
    ignoreUnavailable: !strict,
  );

  /// Query persisted turns without loading the target into a runtime. In
  /// particular, thread/resume can activate a native goal and is forbidden here.
  @override
  Future<SessionTextPage> readTextPage(
    SessionRecord session, {
    String? cursor,
  }) => _withServer(
    session.cwd,
    (server) async {
      final result = await server.request('thread/turns/list', {
        'threadId': session.id,
        'limit': 30,
        'itemsView': 'full',
        'sortDirection': 'desc',
        'cursor': ?cursor,
      });
      final messages = <SessionTextMessage>[];
      for (final turn in (result['data'] as List? ?? const []).reversed) {
        if (turn is! Map) continue;
        for (final item in turn['items'] as List? ?? const []) {
          if (item is! Map) continue;
          final role = switch (item['type']) {
            'userMessage' => 'user',
            'agentMessage' => 'assistant',
            _ => '',
          };
          if (role.isEmpty) continue;
          final text = role == 'assistant'
              ? item['text'] as String? ?? ''
              : [
                  for (final part in item['content'] as List? ?? const [])
                    if (part is Map && part['type'] == 'text' && part['text'] is String)
                      part['text'] as String,
                ].join('\n');
          if (text.isNotEmpty) {
            messages.add(SessionTextMessage(
              role: role,
              text: text,
              id: item['id'] as String?,
            ));
          }
        }
      }
      final next = result['nextCursor'] as String?;
      return SessionTextPage(
        messages: List.unmodifiable(messages),
        nextCursor: next == null || next.isEmpty || next == cursor ? null : next,
      );
    },
    const SessionTextPage(messages: []),
    ignoreUnavailable: false,
    experimentalApi: true,
  );

  /// Preserve history under the new project without rewriting Codex state.
  /// The kernel resumes these records with the supported cwd override.
  @override
  Future<int> moveSessions(String from, String to) async {
    if (RemoteLocation.hostOf(from) != RemoteLocation.hostOf(to)) {
      throw ArgumentError('Codex sessions cannot move between hosts');
    }
    if (CodexSessionLocations.sameLocation(from, to)) return 0;
    final aliases = await _locations.snapshot();
    final known =
        _locationOf.values.any(
          (location) => CodexSessionLocations.sameLocation(location, from),
        ) ||
        aliases.values.any(
          (value) =>
              value is Map &&
              value['to'] is String &&
              CodexSessionLocations.sameLocation(value['to'] as String, from),
        );
    // Every registered catalog is asked during project relocation, even
    // for Claude-only projects on a machine with no Codex installed. An
    // unavailable catalog is harmless only if it has no known history here.
    final sessions = await _sessionsIn(from, strict: known);
    if (sessions.isEmpty) return 0;
    await _locations.move(sessions, to);
    return sessions.length;
  }

  @override
  Future<void> delete(String id) async {
    final location = _locationOf[id];
    await _withServer(location, (server) async {
      await server.request('thread/delete', {'threadId': id});
      await _locations.remove(id, location ?? '');
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
        'cwd': ?cwd,
        // Every provider's, not the default one's alone: a thread on one
        // of BaoCode's models is kept with its provider ([modelRef]).
        'modelProviders': <String>[],
        'limit': 100,
        'cursor': ?cursor,
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
    T empty, {
    bool ignoreUnavailable = true,
    bool experimentalApi = false,
  }) async {
    final CodexTransport transport;
    try {
      transport = await startServer(location);
    } on CodexUnavailable {
      if (!ignoreUnavailable) rethrow;
      // Nothing to list where Codex cannot run (the web).
      return empty;
    }
    final server = _Server(transport);
    try {
      await server.request('initialize', {
        'clientInfo': {'name': 'baocode', 'version': '1.0.0'},
        if (experimentalApi) 'capabilities': {'experimentalApi': true},
      });
      return await body(server);
    } on CodexUnavailable {
      if (!ignoreUnavailable) rethrow;
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
