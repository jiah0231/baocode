import '../../remote/remote_location.dart';
import '../agent_kernel.dart';
import 'codex_session_locations_stub.dart'
    if (dart.library.io) 'codex_session_locations_io.dart'
    as platform;

/// BaoCode's location overrides, not edits to Codex's database or rollouts.
/// An alias is scoped to the thread ID, host and observed original locations.
class CodexSessionLocations {
  CodexSessionLocations({
    this.read = platform.readLocations,
    this.write = platform.writeLocations,
  });

  static final current = CodexSessionLocations();
  final Future<Map<String, Object?>> Function() read;
  final Future<void> Function(Map<String, Object?>) write;
  Future<void> _writing = Future.value();

  static bool sameLocation(String a, String b) =>
      RemoteLocation.hostOf(a) == RemoteLocation.hostOf(b) &&
      RemoteLocation.pathsOf(a)
          .equals(RemoteLocation.pathOf(a), RemoteLocation.pathOf(b));

  Future<Map<String, Object?>> snapshot() async {
    await _writing;
    return read();
  }

  static String _key(SessionRecord session) =>
      '${RemoteLocation.hostOf(session.cwd) ?? ''}\n${session.id}';

  static Map? _alias(Map<String, Object?> data, SessionRecord session) {
    final value = data[_key(session)];
    if (value is! Map ||
        value['to'] is! String ||
        value['from'] is! List ||
        value['rollout'] != session.path) {
      return null;
    }
    final to = value['to'] as String;
    if (RemoteLocation.hostOf(to) != RemoteLocation.hostOf(session.cwd)) {
      return null;
    }
    if (!sameLocation(to, session.cwd) &&
        !(value['from'] as List).whereType<String>().any(
          (from) => sameLocation(from, session.cwd),
        )) {
      return null;
    }
    return value;
  }

  static SessionRecord apply(Map<String, Object?> data, SessionRecord session) {
    final to = _alias(data, session)?['to'] as String?;
    if (to == null) return session;
    return SessionRecord(
      id: session.id,
      title: session.title,
      updatedAt: session.updatedAt,
      cwd: to,
      path: session.path,
    );
  }

  /// Locations to query as well as [location], because Codex may still keep
  /// a moved thread under its original cwd until it is resumed with an override.
  static Set<String> sources(Map<String, Object?> data, String location) => {
    location,
    for (final value in data.values)
      if (value is Map &&
          value['to'] is String &&
          sameLocation(value['to'] as String, location) &&
          value['from'] is List)
        ...(value['from'] as List).whereType<String>().where(
          (from) =>
              RemoteLocation.hostOf(from) == RemoteLocation.hostOf(location),
        ),
  };

  Future<void> remove(String id, String location) {
    final operation = _writing.then((_) async {
      final data = Map<String, Object?>.of(await read());
      data.remove('${RemoteLocation.hostOf(location) ?? ''}\n$id');
      await write(data);
    });
    _writing = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> move(List<SessionRecord> sessions, String to) {
    final operation = _writing.then((_) async {
      final data = await read();
      final next = Map<String, Object?>.of(data);
      for (final session in sessions) {
        final previous = _alias(data, session);
        next[_key(session)] = {
          'from': {
            session.cwd,
            if (previous != null) ...[
              ...(previous['from'] as List).whereType<String>(),
              previous['to'] as String,
            ],
          }.toList(),
          'to': to,
          'rollout': session.path,
        };
      }
      // The caller must see a failed write; do not report a move not persisted.
      await write(next);
    });
    _writing = operation.catchError((Object _) {});
    return operation;
  }
}
