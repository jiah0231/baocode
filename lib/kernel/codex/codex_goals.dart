import '../kernel_types.dart';

/// Codex's native thread goals, not a local evaluator. Only a server's
/// `complete` status means met; a completed chat turn is never a verdict.
/// Protocol: openai/codex app-server v2 ThreadGoal{Set,Get,Clear}.
class CodexGoals {
  CodexGoals({required this.request, required this.report});

  final Future<Map<String, Object?>> Function(
    String method,
    Map<String, Object?> params,
  )
  request;
  final void Function(KernelGoal?) report;
  String? _thread;
  int _revision = 0;
  KernelGoal? current;

  static bool isCommand(String text) =>
      text.trim() == '/goal' || text.trim().startsWith('/goal ');

  /// Switches the source of truth with the thread. In-flight snapshots from
  /// an old thread or before a new notification cannot replace newer state.
  void attach(String threadId) {
    if (_thread == threadId) return;
    _thread = threadId;
    _revision++;
    _publish(null);
  }

  Future<void> refresh() async {
    final thread = _thread;
    if (thread == null) return;
    final revision = _revision;
    try {
      final result = await request('thread/goal/get', {'threadId': thread});
      if (thread != _thread || revision != _revision) return;
      _accept(result['goal']);
    } on Object {
      // Older servers or disabled goals must not break ordinary chat.
      // Explicit commands below still show the server's actionable error.
    }
  }

  /// Explicit user actions carry provenance. Never send automatic success
  /// or modify goal state in response to an assistant's prose.
  Future<void> execute(String text) async {
    final thread = _thread;
    if (thread == null) throw StateError('Start a Codex thread first.');
    final command = text.trim().substring('/goal'.length).trim();
    final revision = ++_revision;
    final Map<String, Object?> result;
    if (command.isEmpty || command == 'status') {
      result = await request('thread/goal/get', {'threadId': thread});
    } else if (command == 'clear') {
      result = await request('thread/goal/clear', {
        'threadId': thread,
        'origin': 'user',
      });
      if (_thread == thread &&
          _revision == revision &&
          result['cleared'] is bool) {
        _publish(null);
      }
      return;
    } else {
      result = await request('thread/goal/set', {
        'threadId': thread,
        'origin': 'user',
        if (command == 'pause')
          'status': 'paused'
        else if (command == 'resume')
          'status': 'active'
        else ...{
          'objective': command,
          'status': 'active',
        },
      });
    }
    if (_thread == thread && _revision == revision) _accept(result['goal']);
  }

  bool notification(String method, Map<String, Object?> params) {
    if (method != 'thread/goal/updated' && method != 'thread/goal/cleared') {
      return false;
    }
    if (params['threadId'] != _thread) return true;
    _revision++;
    if (method == 'thread/goal/cleared') {
      _publish(null);
    } else {
      _accept(params['goal']);
    }
    return true;
  }

  void _accept(Object? raw) {
    if (raw == null) {
      _publish(null);
    } else if (raw is Map && raw['threadId'] == _thread) {
      final parsed = parse(raw);
      if (parsed != null) _publish(parsed);
    }
  }

  void _publish(KernelGoal? goal) {
    current = goal;
    report(goal);
  }

  static KernelGoal? parse(Map<Object?, Object?> raw) {
    final objective = raw['objective'];
    if (objective is! String || objective.trim().isEmpty) return null;
    final status = raw['status'];
    final reason = switch (status) {
      'active' => 'Codex is working toward this goal.',
      'paused' => 'Codex goal paused. Use /goal resume to continue.',
      'blocked' =>
        'Codex reports that this goal is blocked; it is not complete.',
      'usageLimited' => 'Codex goal is waiting for the usage limit to reset.',
      'budgetLimited' =>
        'Codex goal reached its token budget; it is not complete.',
      'complete' => 'Codex reports that this goal is complete.',
      _ => null,
    };
    if (reason == null) return null;
    final createdAt = raw['createdAt'];
    final seconds = raw['timeUsedSeconds'];
    final tokens = raw['tokensUsed'];
    return KernelGoal(
      objective,
      state: status == 'complete' ? GoalState.met : GoalState.active,
      lastReason: reason,
      statusLabel: switch (status) {
        'paused' => 'Paused',
        'blocked' => 'Blocked',
        'usageLimited' => 'Usage limited',
        'budgetLimited' => 'Token budget reached',
        _ => null,
      },
      setAt: createdAt is num && createdAt.isFinite
          ? DateTime.fromMillisecondsSinceEpoch((createdAt * 1000).round())
          : null,
      duration: seconds is num && seconds.isFinite && seconds >= 0
          ? Duration(milliseconds: (seconds * 1000).round())
          : null,
      tokens: tokens is num && tokens.isFinite && tokens >= 0
          ? tokens.round()
          : null,
    );
  }
}
