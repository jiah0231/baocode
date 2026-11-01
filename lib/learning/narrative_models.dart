import 'package:flutter/foundation.dart';

/// A small observed fact, never a whole transcript, prompt or full tool output.
@immutable
class NarrativeFact {
  const NarrativeFact({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    this.sourceItemId,
    this.added,
    this.removed,
    this.excerpt,
  });
  final String id, kind, label, status;
  final String? sourceItemId;
  final String? excerpt;
  final int? added, removed;
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'label': label,
    'status': status,
    if (excerpt != null) 'excerpt': excerpt,
    if (added != null) 'added': added,
    if (removed != null) 'removed': removed,
  };
}

@immutable
class NarrativeSnapshot {
  const NarrativeSnapshot({
    required this.turnId,
    required this.revision,
    required this.facts,
    this.ended = false,
    this.interrupted = false,
    this.omittedCount = 0,
  });
  final String turnId;
  final int revision;
  final List<NarrativeFact> facts;
  final bool ended, interrupted;
  final int omittedCount;
}

@immutable
class NarrativePhase {
  const NarrativePhase({
    required this.id,
    required this.title,
    required this.summary,
    required this.status,
    required this.evidence,
  });
  final String id, title, summary;

  /// observed / inProgress / failed / unconfirmed. Derived from local facts,
  /// not a model assertion that the task or a verification succeeded.
  final String status;
  final List<NarrativeFact> evidence;
}
