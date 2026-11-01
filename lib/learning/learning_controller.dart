import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../chat/chat_models.dart';
import '../kernel/kernel_event.dart';
import 'learning_models.dart';

/// Ephemeral, opt-in teaching projection. It never writes to the conversation,
/// reads files, executes tools, or sends agent thoughts/user messages.
class LearningController extends ChangeNotifier {
  static const maxRequestsPerSession = 24;
  static const maxQueue = 12;
  static const maxCards = 40;
  static const maxContextCharacters = 6000;
  final _queue = ListQueue<LearningEvidence>();
  final _seen = <String>{};
  final _cards = <LearningCard>[];
  LearningGenerator? _generator;
  LearningCancellation? _cancellation;
  Timer? _timer;
  bool _disposed = false;
  bool _enabled = false;
  bool _active = true;
  bool _paused = false;
  bool _busy = false;
  int _generation = 0;
  int _requests = 0;
  String _session = '';
  String? _error;
  Duration _interval = const Duration(seconds: 12);
  LearningDepth _depth = LearningDepth.brief;
  String _languageCode = 'zh';

  bool get enabled => _enabled;
  bool get active => _active;
  bool get paused => _paused;
  bool get busy => _busy;
  String? get error => _error;
  bool get budgetReached => _requests >= maxRequestsPerSession;
  LearningDepth get depth => _depth;
  List<LearningCard> get cards => List.unmodifiable(_cards);
  int get queuedCount => _queue.length;
  int get requestCount => _requests;

  /// The host must first obtain explicit consent to this provider/model and
  /// contextual data transfer. Reconfiguration invalidates any old response.
  void enable(
    LearningGenerator generator, {
    LearningDepth depth = LearningDepth.brief,
    String languageCode = 'zh',
    Duration interval = const Duration(seconds: 12),
  }) {
    if (_disposed) return;
    _invalidate();
    _generator = generator;
    _depth = depth;
    _languageCode = languageCode == 'zh' ? 'zh' : 'en';
    _interval = interval.isNegative ? Duration.zero : interval;
    _enabled = true;
    _paused = false;
    _error = null;
    notifyListeners();
  }

  void disable({bool clearCards = true}) {
    if (_disposed) return;
    _invalidate();
    _enabled = false;
    _generator = null;
    if (clearCards) _cards.clear();
    _error = null;
    notifyListeners();
  }

  /// Visibility/task focus is independent of the user's explicit pause.
  /// Leaving the task never accumulates a paid backlog for later.
  void setActive(bool value) {
    if (_disposed || _active == value) return;
    _active = value;
    if (!value) _invalidate();
    notifyListeners();
  }

  void setPaused(bool value) {
    if (_disposed || _paused == value) return;
    _paused = value;
    if (value) _invalidate();
    notifyListeners();
  }

  void setDepth(LearningDepth value) {
    if (_disposed || value == _depth) return;
    _depth = value;
    _invalidate();
    notifyListeners();
  }

  void switchSession(String session) {
    if (_disposed || session == _session) return;
    _session = session;
    _invalidate();
    _cards.clear();
    _seen.clear();
    _requests = 0;
    _error = null;
    notifyListeners();
  }

  void _invalidate() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _queue.clear();
    _cancellation?.cancel();
    // Do not release the single-flight slot until its transport settles.
  }

  /// Call only for newly applied LIVE events, never restored history. For
  /// ItemCompleted with no item, the host can supply its resolved item.
  void observe(KernelEvent event, {ChatItem? completedItem}) {
    if (_disposed) return;
    if (event is Rewound || event is ChangesReverted) {
      _invalidate();
      _cards.clear();
      notifyListeners();
      return;
    }
    if (!_enabled || !_active || _paused || budgetReached) return;
    LearningEvidence? evidence;
    if (event is ItemCompleted) {
      evidence = _fromItem(event.id, event.item ?? completedItem);
    } else if (event is ItemUpserted && !event.streaming) {
      evidence = _fromItem(event.id, event.item);
    } else if (event is FileEdited && !event.change.binary) {
      final change = event.change;
      if (!_sensitivePath(change.path)) {
        evidence = LearningEvidence(
          id: 'edit:${event.seq}',
          kind: 'file-summary',
          label: _safeLabel(change.fileName),
          path: change.path,
          excerpt:
              'Reported ${change.kind.name}: +${change.added} / -${change.removed} lines. Code and intent are not available in this record.',
        );
      }
    }
    if (evidence == null) return;
    // Prefer actual changed code to its nearby file-count notification.
    final pendingEvidence = evidence;
    if (pendingEvidence.path != null) {
      if (pendingEvidence.kind == 'file-summary' &&
          _queue.any(
            (e) => e.path == pendingEvidence.path && e.kind == 'diff',
          )) {
        return;
      }
      if (pendingEvidence.kind == 'diff') {
        _queue.removeWhere(
          (e) => e.path == pendingEvidence.path && e.kind == 'file-summary',
        );
      }
    }
    final fingerprint = sha256
        .convert(
          utf8.encode(
            '${evidence.kind}\n${evidence.label}\n${evidence.excerpt}',
          ),
        )
        .toString();
    if (!_seen.add(fingerprint)) return;
    if (_seen.length > 512) _seen.remove(_seen.first);
    if (_queue.length >= maxQueue) _queue.removeFirst();
    _queue.add(evidence);
    _schedule();
  }

  LearningEvidence? _fromItem(String id, ChatItem? item) {
    String kind;
    String label;
    String excerpt;
    String? path;
    switch (item) {
      case CodeDiffItem():
        if (_sensitivePath(item.path)) return null;
        kind = 'diff';
        label = item.fileName;
        path = item.path;
        excerpt = item.lines
            .take(48)
            .map(
              (line) =>
                  '${switch (line.type) {
                    DiffLineType.added => '+',
                    DiffLineType.removed => '-',
                    DiffLineType.context => ' ',
                  }}${_clip(line.text, 220)}',
            )
            .join('\n');
      case ToolCallItem(status: ToolStatus.succeeded, kind: ToolKind.edit):
        path =
            item.path ??
            (item.input['file_path'] is String
                ? item.input['file_path'] as String
                : null);
        if (_sensitiveCommand(item.target)) return null;
        if (path != null && _sensitivePath(path)) return null;
        kind = 'edit';
        label = item.label ?? 'Code edit';
        // Only explicitly selected edit fields, never arbitrary tool input.
        final before = item.input['old_string'];
        final after = item.input['new_string'];
        if (before is String && after is String) {
          excerpt =
              'Before:\n${_clip(before, 1200)}\nAfter:\n${_clip(after, 1200)}';
        } else {
          final patch = item.input['patch'] ?? item.input['patchText'];
          if (patch is! String || _sensitiveCommand(patch)) return null;
          excerpt = _clip(patch, 2400);
        }
      case TerminalItem(
        status: CommandStatus.succeeded || CommandStatus.failed,
      ):
        if (_sensitiveCommand(item.command)) return null;
        kind = 'command';
        label = item.description ?? 'Completed command';
        excerpt =
            'Observed status: ${item.status.name}. Command: ${_clip(item.command, 450)}\nOutput excerpt:\n${_clip(item.output, 1800)}';
      case ToolCallItem(
        status: ToolStatus.succeeded || ToolStatus.failed,
        kind: ToolKind.command,
      ):
        if (_sensitiveCommand(item.target)) return null;
        kind = 'command';
        label = item.label ?? 'Completed command';
        excerpt =
            'Observed status: ${item.status.name}. Command: ${_clip(item.target, 450)}\nOutput excerpt:\n${_clip(item.output ?? '', 1800)}';
      default:
        return null;
    }
    if (excerpt.trim().isEmpty) return null;
    return LearningEvidence(
      id: id,
      kind: kind,
      label: _safeLabel(label),
      excerpt: redactLearningText(_clip(excerpt, 2600)),
      sourceItemId: id,
      path: path,
    );
  }

  void _schedule() {
    if (_disposed ||
        !_enabled ||
        !_active ||
        _paused ||
        _busy ||
        _timer != null ||
        _queue.isEmpty ||
        budgetReached) {
      return;
    }
    _timer = Timer(_interval, () {
      _timer = null;
      unawaited(_generate());
    });
  }

  Future<void> _generate() async {
    if (_disposed ||
        !_enabled ||
        !_active ||
        _paused ||
        _busy ||
        _queue.isEmpty ||
        budgetReached) {
      return;
    }
    final generator = _generator;
    if (generator == null) return;
    final generation = _generation;
    final cancellation = LearningCancellation();
    _cancellation = cancellation;
    final evidence = <LearningEvidence>[];
    var characters = 0;
    while (_queue.isNotEmpty && evidence.length < 3) {
      final next = _queue.first;
      final size = jsonEncode(next.toJson()).length;
      if (characters + size > maxContextCharacters) break;
      evidence.add(_queue.removeFirst());
      characters += size;
    }
    if (evidence.isEmpty) {
      _queue.removeFirst();
      _schedule();
      return;
    }
    _busy = true;
    _requests++;
    if (budgetReached) _queue.clear();
    _error = null;
    notifyListeners();
    try {
      final output = await generator.generate(
        LearningRequest(
          evidence: List.unmodifiable(evidence),
          depth: _depth,
          languageCode: _languageCode,
        ),
        cancellation,
      );
      if (_disposed || generation != _generation || cancellation.isCancelled) {
        return;
      }
      final card = _validate(output, evidence);
      _cards.add(card);
      if (_cards.length > maxCards) _cards.removeAt(0);
    } catch (_) {
      if (!_disposed &&
          generation == _generation &&
          !cancellation.isCancelled) {
        // Never surface transport exception bodies: they can contain keys,
        // provider payloads, or raw private evidence.
        _error = '讲解暂时不可用。请检查模型设置；主任务不受影响。';
      }
    } finally {
      _busy = false;
      if (identical(_cancellation, cancellation)) _cancellation = null;
      if (!_disposed) {
        notifyListeners();
        _schedule();
      }
    }
  }

  LearningCard _validate(
    Map<String, Object?> output,
    List<LearningEvidence> evidence,
  ) {
    String field(String name, int max) {
      final value = output[name];
      if (value is! String || value.trim().isEmpty || value.length > max) {
        throw const FormatException('Invalid teaching card');
      }
      return redactLearningText(value.trim());
    }

    String? optional(String name) =>
        output[name] == null ? null : field(name, 900);
    final ids = output['evidenceIds'];
    final known = {for (final item in evidence) item.id: item};
    if (ids is! List ||
        ids.isEmpty ||
        ids.length > evidence.length ||
        ids.any((id) => id is! String || !known.containsKey(id))) {
      throw const FormatException('Unknown evidence');
    }
    return LearningCard(
      id: '$_session:$_generation:$_requests',
      title: field('title', 100),
      summary: field('summary', 400),
      why: field('why', 900),
      concept: field('concept', 900),
      example: optional('example'),
      tradeoff: optional('tradeoff'),
      evidence: List.unmodifiable(ids.toSet().map((id) => known[id]!)),
      createdAt: DateTime.now(),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidate();
    _cards.clear();
    _seen.clear();
    super.dispose();
  }
}

bool _sensitiveCommand(String command) =>
    command.length > 16000 ||
    _sensitivePath(command) ||
    RegExp(
      r'(^|[\s;&|/\\])(?:env|printenv|set|export)(?:\s|$)|(?:\.env|\.ssh|\.aws|credentials|secrets?|id_rsa|id_ed25519|\.(?:pem|p12|pfx)\b)',
      caseSensitive: false,
    ).hasMatch(command);

String _clip(String value, int max) => value.length <= max
    ? value
    : '${value.substring(0, max)}\n[excerpt truncated]';
String _safeLabel(String value) =>
    redactLearningText(_clip(value.replaceAll(RegExp(r'\s+'), ' '), 120));
bool _sensitivePath(String path) => RegExp(
  r'(^|[/\\])(\.env([^/\\]*)?|\.git|\.ssh|\.aws|credentials?([^/\\]*)?|secrets?([^/\\]*)?|id_rsa|id_ed25519)([/\\]|$)|\.(pem|key|p12|pfx)$',
  caseSensitive: false,
).hasMatch(path);

/// Defense in depth, not a guarantee: explicit enablement still warns that
/// selected code/tool excerpts leave the device. No transcript is forwarded.
String redactLearningText(String text) {
  var value = text.replaceAll(
    RegExp(
      r'-----BEGIN [^-]*(PRIVATE KEY|CERTIFICATE)-----[\s\S]*?(-----END [^-]+-----|$)',
    ),
    '[REDACTED KEY]',
  );
  value = value.replaceAll(
    RegExp(
      r'\b(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,}|AKIA[A-Z0-9]{16})\b',
    ),
    '[REDACTED TOKEN]',
  );
  value = value.replaceAll(
    RegExp(r'bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    'Bearer [REDACTED]',
  );
  value = value.replaceAllMapped(
    RegExp(
      r'''\b(api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|passwd|client[_-]?secret|secret[_-]?key|private[_-]?key|secret|authorization)\b["']?\s*[:=]\s*["']?[^\s,"';]+''',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}=[REDACTED]',
  );
  value = value.replaceAll(
    RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
    '[REDACTED TOKEN]',
  );
  value = value.replaceAllMapped(
    RegExp(
      r'''--(token|api-key|password|secret)(?:=|\s+)[^\s]+''',
      caseSensitive: false,
    ),
    (m) => '--${m.group(1)}=[REDACTED]',
  );
  value = value.replaceAll(
    RegExp(r'https?://[^\s/@:]+:[^\s/@]+@'),
    'https://[REDACTED]@',
  );
  return value.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');
}
