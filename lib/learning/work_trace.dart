import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../chat/chat_models.dart';
import '../kernel/kernel_event.dart';
import 'learning_controller.dart' show redactLearningText;

enum WorkTraceKind { command, task, tool, file }

enum WorkTraceStatus { running, completed, failed, denied, unknown }

@immutable
class WorkTraceEntry {
  const WorkTraceEntry({
    required this.id,
    required this.kind,
    required this.status,
    required this.label,
    this.sourceItemId,
    this.added,
    this.removed,
    this.background = false,
  });

  final String id;
  final WorkTraceKind kind;
  final WorkTraceStatus status;
  final String label;
  final String? sourceItemId;
  final int? added, removed;
  final bool background;
}

/// Facts about this turn, from accepted runtime events. No model, transcript,
/// prompts, command output, or hidden reasoning is retained here.
class WorkTraceController extends ChangeNotifier {
  static const maxEntries = 80;
  final LinkedHashMap<String, WorkTraceEntry> _entries = LinkedHashMap();
  int _lastSeq = -1;
  int _omitted = 0;
  bool _disposed = false;
  String? _turnId;
  bool _ended = false;
  bool _interrupted = false;

  List<WorkTraceEntry> get entries => List.unmodifiable(_entries.values);
  String? get currentTurnId => _turnId;
  int get omittedCount => _omitted;
  bool get ended => _ended;
  bool get interrupted => _interrupted;

  /// A replacement kernel has its own sequence space and turn identity.
  void reset() {
    if (_disposed) return;
    _entries.clear();
    _lastSeq = -1;
    _omitted = 0;
    _turnId = null;
    _ended = false;
    _interrupted = false;
    notifyListeners();
  }

  void accept(KernelEvent event, {ChatItem? completedItem}) {
    if (_disposed || event.seq <= _lastSeq) return;
    _lastSeq = event.seq;
    // Token streams, thought updates and history never enumerate entries,
    // allocate presentation snapshots or notify listeners.
    if (event is! TurnStarted &&
        event is! TurnEnded &&
        event is! ItemUpserted &&
        event is! ItemCompleted &&
        event is! ItemRemoved &&
        event is! FileEdited) {
      return;
    }
    if (event is TurnStarted) {
      if (_turnId == event.turnId) return;
      _entries.clear();
      _omitted = 0;
      _turnId = event.turnId;
      _ended = false;
      _interrupted = false;
      notifyListeners();
      return;
    }
    if (_turnId == null) return;
    if (event is TurnEnded && event.turnId == _turnId) {
      _ended = true;
      _interrupted = event.interrupted;
      // Ending a turn is not evidence that a particular command succeeded
      // or was cancelled. Background jobs may still be running.
      for (final entry in _entries.values.toList()) {
        if (entry.status == WorkTraceStatus.running && !entry.background) {
          _entries[entry.id] = WorkTraceEntry(
            id: entry.id,
            kind: entry.kind,
            status: WorkTraceStatus.unknown,
            label: entry.label,
            sourceItemId: entry.sourceItemId,
            added: entry.added,
            removed: entry.removed,
          );
        }
      }
      notifyListeners();
    } else if (event is ItemUpserted) {
      _item(event.id, event.item);
    } else if (event is ItemCompleted) {
      // The caller resolves this one item through Transcript.indexOf, not a
      // scan of history. Completion alone does not imply a successful result.
      final item = event.item ?? completedItem;
      if (item != null) _item(event.id, item);
    } else if (event is ItemRemoved) {
      if (_entries.remove(event.id) != null) notifyListeners();
    } else if (event is FileEdited) {
      if (event.turnId != null && event.turnId != _turnId) return;
      final change = event.change;
      final id = event.sourceItemId ?? 'file:${event.seq}';
      _put(
        WorkTraceEntry(
          id: id,
          sourceItemId: event.sourceItemId,
          kind: WorkTraceKind.file,
          status: WorkTraceStatus.completed,
          label: _short(change.fileName),
          added: change.binary ? null : change.added,
          removed: change.binary ? null : change.removed,
        ),
      );
    }
  }

  void _item(String id, ChatItem item) {
    final WorkTraceEntry entry;
    if (item is TerminalItem) {
      entry = WorkTraceEntry(
        id: id,
        sourceItemId: id,
        kind: WorkTraceKind.command,
        status: _commandStatus(item.status),
        // The command itself may contain secrets or huge inline scripts.
        label: item.description == null ? '' : _short(item.description!),
        background: item.background,
      );
    } else if (item is AgentItem) {
      entry = WorkTraceEntry(
        id: id,
        sourceItemId: id,
        kind: WorkTraceKind.task,
        status: _commandStatus(item.status),
        label: _short(item.description),
        background: item.background,
      );
    } else if (item is ToolCallItem) {
      // Reads/searches are routine noise, not a second execution log.
      if ({
        ToolKind.read,
        ToolKind.grep,
        ToolKind.search,
        ToolKind.listDir,
        ToolKind.todo,
      }.contains(item.kind)) {
        return;
      }
      entry = WorkTraceEntry(
        id: id,
        sourceItemId: id,
        kind: WorkTraceKind.tool,
        status: switch (item.status) {
          ToolStatus.running => WorkTraceStatus.running,
          ToolStatus.succeeded => WorkTraceStatus.completed,
          ToolStatus.failed => WorkTraceStatus.failed,
          ToolStatus.denied => WorkTraceStatus.denied,
        },
        label: _short(item.label ?? item.kind.name),
      );
    } else {
      // Diff previews are not confirmation of an actual file change.
      return;
    }
    _put(entry);
  }

  void _put(WorkTraceEntry entry) {
    final old = _entries[entry.id];
    if (old != null &&
        old.kind == entry.kind &&
        old.status == entry.status &&
        old.label == entry.label &&
        old.added == entry.added &&
        old.removed == entry.removed &&
        old.sourceItemId == entry.sourceItemId &&
        old.background == entry.background) {
      return;
    }
    _entries[entry.id] = entry;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
      _omitted++;
    }
    notifyListeners();
  }

  static WorkTraceStatus _commandStatus(CommandStatus status) =>
      switch (status) {
        CommandStatus.running => WorkTraceStatus.running,
        CommandStatus.succeeded => WorkTraceStatus.completed,
        CommandStatus.failed => WorkTraceStatus.failed,
      };

  static String _short(String value) {
    final text = redactLearningText(
      value.length > 4096 ? value.substring(0, 4096) : value,
    ).replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }

  @override
  void dispose() {
    _disposed = true;
    _entries.clear();
    super.dispose();
  }
}
