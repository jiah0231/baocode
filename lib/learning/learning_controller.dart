import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../chat/chat_models.dart';
import '../kernel/kernel_event.dart';
import 'learning_models.dart';
import 'narrative_models.dart';

/// Ephemeral, opt-in teaching projection. It never writes to the conversation,
/// reads files, executes tools, or sends agent thoughts/user messages.
class LearningController extends ChangeNotifier {
  static const maxRequestsPerSession = 24;
  static const maxQueue = 12;
  static const maxCards = 40;
  static const maxContextCharacters = 6000;
  final _queue = ListQueue<LearningEvidence>();
  // Diff items can be previews awaiting permission (not completed edits).
  // Retain only minimized candidates until a FileEdited confirms the exact operation ID and path.
  final _diffCandidates = <String, LearningEvidence>{};
  final _seen = <String>{};
  final _itemFingerprints = <String, String>{};
  String? _busyItemId;
  final _confirmedEvidence = <String, LearningEvidence>{};
  NarrativeSnapshot? _latestNarrative, _pendingNarrative, _narrativeInFlight;
  final _narrativePhases = <NarrativePhase>[];
  bool _lastWasNarrative = false;
  String? _narrativeError;
  int _narrativeRevision = -1;
  int _narrativeOmitted = 0;

  List<NarrativePhase> get narrativePhases =>
      List.unmodifiable(_narrativePhases);
  bool get narrativeBusy => _narrativeInFlight != null;
  String? get narrativeError => _narrativeError;
  String? get narrativeTurnId => _latestNarrative?.turnId;
  bool get narrativeEnded => _latestNarrative?.ended ?? false;
  int get narrativeRevision => _narrativeRevision;
  int get narrativeOmittedCount {
    final latest = _latestNarrative?.omittedCount ?? 0;
    return latest > _narrativeOmitted ? latest : _narrativeOmitted;
  }

  bool get explanationBudgetReached => _requests >= maxRequestsPerSession - 2;
  // The final two slots are never spent on bubbles. The last slot is reserved
  // for an ended snapshot, so continuous narration cannot starve the recap.
  bool get _canNarrate =>
      _pendingNarrative != null &&
      !budgetReached &&
      (_requests < maxRequestsPerSession - 1 || _pendingNarrative!.ended);
  bool get _canExplain =>
      _queue.isNotEmpty && _requests < maxRequestsPerSession - 2;
  bool get _hasWork => _canNarrate || _canExplain;
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
  String? get busyItemId => _busyItemId;

  /// Never infer a bubble anchor from a filename, position or adjacent card.
  LearningCard? cardForItem(String itemId) {
    for (final card in _cards.reversed) {
      if (card.sourceItemId == itemId) return card;
    }
    return null;
  }

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
    if (clearCards) {
      _cards.clear();
      _narrativePhases.clear();
    }
    _narrativeError = null;
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
    _itemFingerprints.clear();
    _latestNarrative = null;
    _narrativePhases.clear();
    _narrativeError = null;
    _narrativeRevision = -1;
    _requests = 0;
    _lastWasNarrative = false;
    _error = null;
    notifyListeners();
  }

  void _invalidate() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _queue.clear();
    _diffCandidates.clear();
    _confirmedEvidence.clear();
    _pendingNarrative = null;
    _cancellation?.cancel();
    // Do not release the single-flight slot until its transport settles.
  }

  /// Call only for newly applied LIVE events, never restored history. For
  /// ItemCompleted with no item, the host can supply its resolved item.
  void observe(
    KernelEvent event, {
    ChatItem? completedItem,
    bool allowGeneration = true,
  }) {
    if (_disposed) return;
    if (event is Rewound || event is ChangesReverted) {
      _invalidate();
      _cards.clear();
      _narrativePhases.clear();
      _latestNarrative = null;
      notifyListeners();
      return;
    }
    if (event is TurnEnded) {
      _diffCandidates.clear();
      return;
    }
    // Outside a known live turn, revisions may invalidate a retained bubble,
    // but restored/history events must never create a paid request.
    if (!allowGeneration || !_enabled || !_active || _paused) {
      final id = switch (event) {
        ItemCompleted(:final id) ||
        ItemUpserted(:final id) ||
        ItemRemoved(:final id) => id,
        _ => null,
      };
      if (id != null) _forgetItem(id);
      return;
    }
    if (event is ItemRemoved) {
      _forgetItem(event.id);
      return;
    }
    final reportedItem = switch (event) {
      ItemCompleted(:final item) => item ?? completedItem,
      ItemUpserted(:final item) => item,
      _ => null,
    };
    final reportedId = switch (event) {
      ItemCompleted(:final id) || ItemUpserted(:final id) => id,
      _ => null,
    };
    if (reportedId != null &&
        (reportedItem is TerminalItem &&
                reportedItem.status == CommandStatus.running ||
            reportedItem is ToolCallItem &&
                reportedItem.status != ToolStatus.succeeded &&
                reportedItem.status != ToolStatus.failed)) {
      _forgetItem(reportedId);
    }
    if (reportedItem is ToolCallItem &&
        reportedItem.kind == ToolKind.edit &&
        (reportedItem.status == ToolStatus.denied ||
            reportedItem.status == ToolStatus.failed)) {
      // A denied/failed edit cannot confirm any staged preview.
      if (reportedId != null) _forgetItem(reportedId);
      return;
    }
    LearningEvidence? evidence;
    if (event is ItemCompleted) {
      evidence = _fromItem(event.id, event.item ?? completedItem);
    } else if (event is ItemUpserted &&
        (!event.streaming || event.item is CodeDiffItem)) {
      evidence = _fromItem(event.id, event.item);
    } else if (event is FileEdited && !event.change.binary) {
      final change = event.change;
      final sourceId = event.sourceItemId;
      if (sourceId == null || _sensitivePath(change.path)) return;
      final candidate = _diffCandidates.remove(sourceId);
      if (candidate != null &&
          _pathKey(candidate.path!) != _pathKey(change.path)) {
        return;
      }
      evidence =
          candidate ??
          LearningEvidence(
            id: 'edit:${event.seq}',
            kind: 'file-summary',
            label: _safeLabel(change.fileName),
            sourceItemId: sourceId,
            path: change.path,
            excerpt:
                'Reported ${change.kind.name}: +${change.added} / -${change.removed} lines. Code and intent are not available in this record.',
          );
    }
    if (evidence == null || evidence.sourceItemId == null) return;
    final fingerprint = _fingerprint(evidence);
    final itemId = evidence.sourceItemId!;
    if (_itemFingerprints[itemId] != fingerprint) {
      _forgetItem(itemId);
      _itemFingerprints[itemId] = fingerprint;
      if (_itemFingerprints.length > 512) {
        _forgetItem(_itemFingerprints.keys.first);
      }
    }
    if (budgetReached) return;
    if (evidence.kind == 'diff' && event is! FileEdited) {
      _stageDiff(evidence);
      return;
    }
    _confirmedEvidence[itemId] = evidence;
    while (_confirmedEvidence.length > maxQueue ||
        _confirmedEvidence.values.fold<int>(
              0,
              (sum, item) => sum + jsonEncode(item.toJson()).length,
            ) >
            maxContextCharacters) {
      _confirmedEvidence.remove(_confirmedEvidence.keys.first);
    }
    if (!_seen.add(fingerprint)) return;
    if (_seen.length > 512) _seen.remove(_seen.first);
    if (_queue.length >= maxQueue) _queue.removeFirst();
    _queue.add(evidence);
    _schedule();
  }

  void _stageDiff(LearningEvidence evidence) {
    final key = evidence.sourceItemId;
    if (key == null || evidence.path == null) return;
    _diffCandidates.remove(key);
    _diffCandidates[key] = evidence;
    // Bound both count and serialized context, not just number of files.
    while (_diffCandidates.length > maxQueue ||
        _diffCandidates.values.fold<int>(
              0,
              (sum, item) => sum + jsonEncode(item.toJson()).length,
            ) >
            maxContextCharacters) {
      _diffCandidates.remove(_diffCandidates.keys.first);
    }
  }

  static String _fingerprint(LearningEvidence evidence) => sha256
      .convert(
        utf8.encode(
          '${evidence.sourceItemId}\n${evidence.kind}\n${evidence.path}\n${evidence.label}\n${evidence.excerpt}',
        ),
      )
      .toString();

  void _forgetItem(String itemId) {
    _itemFingerprints.remove(itemId);
    _confirmedEvidence.remove(itemId);
    NarrativeSnapshot? withoutSource(NarrativeSnapshot? snapshot) {
      if (snapshot == null) return null;
      return NarrativeSnapshot(
        turnId: snapshot.turnId,
        revision: snapshot.revision,
        facts: List.unmodifiable(
          snapshot.facts.where((fact) => fact.sourceItemId != itemId),
        ),
        ended: snapshot.ended,
        interrupted: snapshot.interrupted,
        omittedCount: snapshot.omittedCount,
      );
    }

    _latestNarrative = withoutSource(_latestNarrative);
    _pendingNarrative = withoutSource(_pendingNarrative);
    if (_pendingNarrative?.facts.isEmpty ?? false) _pendingNarrative = null;
    final oldPhaseCount = _narrativePhases.length;
    _narrativePhases.removeWhere(
      (phase) => phase.evidence.any((fact) => fact.sourceItemId == itemId),
    );
    if (_narrativeInFlight?.facts.any((fact) => fact.sourceItemId == itemId) ??
        false) {
      _cancellation?.cancel();
    }
    if (oldPhaseCount != _narrativePhases.length) notifyListeners();
    _diffCandidates.remove(itemId);
    _queue.removeWhere((item) => item.sourceItemId == itemId);
    final hadCard = _cards.any((card) => card.sourceItemId == itemId);
    _cards.removeWhere((card) => card.sourceItemId == itemId);
    if (_busyItemId == itemId) _cancellation?.cancel();
    if (hadCard) notifyListeners();
  }

  static String _pathKey(String path) => path.replaceAll(r'\', '/');

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
        !_hasWork ||
        budgetReached) {
      return;
    }
    _timer = Timer(_interval, () {
      _timer = null;
      unawaited(_generate());
    });
  }

  /// Only a bridge of accepted live runtime facts may call this method.
  /// The latest snapshot replaces pending work rather than growing a queue.
  void submitNarrative(NarrativeSnapshot snapshot) {
    if (_disposed) return;
    final previous = _latestNarrative;
    if (previous != null &&
        previous.turnId == snapshot.turnId &&
        snapshot.revision <= previous.revision) {
      return;
    }
    if (previous?.turnId != snapshot.turnId) {
      _lastWasNarrative = false;
      _narrativePhases.clear();
      _narrativeRevision = -1;
      _narrativeOmitted = 0;
      if (_narrativeInFlight != null) _cancellation?.cancel();
    }
    final facts = <NarrativeFact>[];
    final factIds = <String>{};
    for (final fact in snapshot.facts.reversed.take(12).toList().reversed) {
      if (fact.id.isEmpty ||
          fact.id.length > 256 ||
          (fact.sourceItemId?.length ?? 0) > 256 ||
          !factIds.add(fact.id) ||
          !{
            'running',
            'completed',
            'failed',
            'denied',
            'unknown',
          }.contains(fact.status) ||
          _sensitivePath(fact.label)) {
        continue;
      }
      final confirmed = _confirmedEvidence[fact.sourceItemId];
      facts.add(
        NarrativeFact(
          id: fact.id,
          kind: _clip(fact.kind, 40),
          label: _safeLabel(fact.label),
          status: fact.status,
          sourceItemId: fact.sourceItemId,
          added: fact.added,
          removed: fact.removed,
          excerpt: confirmed == null
              ? null
              : redactLearningText(_clip(confirmed.excerpt, 900)),
        ),
      );
    }
    final clean = NarrativeSnapshot(
      turnId: snapshot.turnId,
      revision: snapshot.revision,
      facts: List.unmodifiable(facts),
      ended: snapshot.ended,
      interrupted: snapshot.interrupted,
      omittedCount:
          snapshot.omittedCount + snapshot.facts.length - facts.length,
    );
    _latestNarrative = clean;
    final known = {
      for (final fact in facts) fact.id: jsonEncode(fact.toJson()),
    };
    _narrativePhases.removeWhere(
      (phase) => phase.evidence.any(
        (fact) => known[fact.id] != jsonEncode(fact.toJson()),
      ),
    );
    if (_enabled && _active && !_paused && facts.isNotEmpty && !budgetReached) {
      _pendingNarrative = clean;
      _schedule();
    } else {
      _pendingNarrative = null;
    }
    notifyListeners();
  }

  LearningRequest _narrativeRequest(NarrativeSnapshot snapshot) {
    final facts = snapshot.facts.toList();
    var phases = _narrativePhases.toList();
    LearningRequest build() {
      final bounded = NarrativeSnapshot(
        turnId: snapshot.turnId,
        revision: snapshot.revision,
        facts: List.unmodifiable(facts),
        ended: snapshot.ended,
        interrupted: snapshot.interrupted,
        omittedCount:
            snapshot.omittedCount + snapshot.facts.length - facts.length,
      );
      return LearningRequest(
        kind: LearningRequestKind.narrative,
        narrative: bounded,
        depth: _depth,
        languageCode: _languageCode,
        evidence: List.unmodifiable([
          for (final fact in facts)
            LearningEvidence(
              id: fact.id,
              kind: fact.kind,
              label: fact.label,
              excerpt: jsonEncode(fact.toJson()),
              sourceItemId: fact.sourceItemId,
            ),
        ]),
        previousPhases: List.unmodifiable(phases),
      );
    }

    var request = build();
    if (jsonEncode(request.toJson()).length > maxContextCharacters) {
      phases = [];
      request = build();
    }
    while (facts.isNotEmpty &&
        jsonEncode(request.toJson()).length > maxContextCharacters) {
      facts.removeAt(0);
      request = build();
    }
    return request;
  }

  Future<void> _generate() async {
    if (_disposed ||
        !_enabled ||
        !_active ||
        _paused ||
        _busy ||
        !_hasWork ||
        budgetReached) {
      return;
    }
    final generator = _generator;
    if (generator == null) return;
    final generation = _generation;
    final cancellation = LearningCancellation();
    _cancellation = cancellation;
    final useNarrative = _canNarrate && (!_canExplain || !_lastWasNarrative);
    late final LearningRequest request;
    if (useNarrative) {
      request = _narrativeRequest(_pendingNarrative!);
      _pendingNarrative = null;
      if (request.evidence.isEmpty) {
        _schedule();
        return;
      }
      _narrativeInFlight = request.narrative;
      _narrativeError = null;
    } else {
      final evidence = _queue.removeFirst();
      if (jsonEncode(evidence.toJson()).length > maxContextCharacters) {
        _schedule();
        return;
      }
      request = LearningRequest(
        evidence: List.unmodifiable([evidence]),
        depth: _depth,
        languageCode: _languageCode,
      );
      _busyItemId = evidence.sourceItemId;
      _error = null;
    }
    _lastWasNarrative = useNarrative;
    _busy = true;
    _requests++;
    if (_requests >= maxRequestsPerSession - 2) {
      _queue.clear();
    }
    if (budgetReached) _pendingNarrative = null;
    notifyListeners();
    try {
      final output = await generator.generate(request, cancellation);
      if (_disposed || generation != _generation || cancellation.isCancelled)
        return;
      if (useNarrative) {
        final phases = _validateNarrative(output, request.narrative!);
        if (phases != null) {
          _narrativePhases
            ..clear()
            ..addAll(phases);
          _narrativeRevision = request.narrative!.revision;
          _narrativeOmitted = request.narrative!.omittedCount;
        }
      } else {
        final evidence = request.evidence.single;
        if (_itemFingerprints[evidence.sourceItemId] != _fingerprint(evidence))
          return;
        final card = _validate(output, request.evidence);
        _cards.removeWhere((old) => old.sourceItemId == card.sourceItemId);
        _cards.add(card);
        if (_cards.length > maxCards) _cards.removeAt(0);
      }
    } catch (_) {
      if (!_disposed &&
          generation == _generation &&
          !cancellation.isCancelled) {
        if (useNarrative) {
          _narrativeError = '工作脉络暂时未能整理。主任务不受影响。';
        } else {
          _error = '讲解暂时不可用。请检查模型设置；主任务不受影响。';
        }
      }
    } finally {
      _busy = false;
      _busyItemId = null;
      _narrativeInFlight = null;
      if (identical(_cancellation, cancellation)) _cancellation = null;
      if (!_disposed) {
        notifyListeners();
        _schedule();
      }
    }
  }

  List<NarrativePhase>? _validateNarrative(
    Map<String, Object?> output,
    NarrativeSnapshot snapshot,
  ) {
    final current = _latestNarrative;
    if (current == null || current.turnId != snapshot.turnId) return null;
    final raw = output['phases'];
    if (raw is! List || raw.isEmpty || raw.length > 5)
      throw const FormatException('Invalid phases');
    final known = {for (final fact in snapshot.facts) fact.id: fact};
    final latest = {for (final fact in current.facts) fact.id: fact};
    final phaseIds = <String>{};
    final phases = <NarrativePhase>[];
    for (final value in raw) {
      if (value is! Map) throw const FormatException('Invalid phase');
      final id = value['id'],
          title = value['title'],
          summary = value['summary'],
          ids = value['evidenceIds'];
      if (id is! String ||
          !RegExp(r'^phase-[1-5]$').hasMatch(id) ||
          !phaseIds.add(id) ||
          title is! String ||
          title.trim().isEmpty ||
          title.length > 80 ||
          summary is! String ||
          summary.trim().isEmpty ||
          summary.length > 360 ||
          ids is! List ||
          ids.isEmpty ||
          ids.length > 12 ||
          ids.any((id) => id is! String || !known.containsKey(id))) {
        throw const FormatException('Ungrounded phase');
      }
      final facts = ids.toSet().map((id) => known[id]!).toList();
      // Appended facts do not starve a valid in-flight summary. Modified or
      // removed referenced facts and a new turn always invalidate it.
      if (facts.any(
        (fact) =>
            latest[fact.id] == null ||
            jsonEncode(latest[fact.id]!.toJson()) != jsonEncode(fact.toJson()),
      )) {
        return null;
      }
      final status = facts.any((f) => f.status == 'failed')
          ? 'failed'
          : facts.any((f) => f.status == 'denied' || f.status == 'unknown')
          ? 'unconfirmed'
          : facts.any((f) => f.status == 'running')
          ? 'inProgress'
          : 'observed';
      if (value['status'] != status)
        throw const FormatException('Unsupported outcome');
      phases.add(
        NarrativePhase(
          id: '${snapshot.turnId}:$id',
          title: redactLearningText(title.trim()),
          summary: redactLearningText(summary.trim()),
          status: status,
          evidence: List.unmodifiable(facts),
        ),
      );
    }
    return phases;
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
    if (evidence.length != 1 ||
        evidence.single.sourceItemId == null ||
        ids is! List ||
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
    _itemFingerprints.clear();
    _narrativePhases.clear();
    _latestNarrative = null;
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

/// Shared privacy filter for local progress-fact collection.
bool isLearningSensitivePath(String path) => _sensitivePath(path);
bool isLearningSensitiveCommand(String command) => _sensitiveCommand(command);
