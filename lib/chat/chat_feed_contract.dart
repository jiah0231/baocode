import 'package:flutter/foundation.dart';

import 'chat_models.dart';
import 'composer/composer_draft.dart';
import 'composer/composer_message.dart';

/// A conversation as a history view shows it: its items, and what can be
/// done to them. A session's own, or a subagent's within it.
abstract interface class ChatFeed implements Listenable {
  int get itemCount;
  ChatItem itemAt(int index);

  /// Whether it is still being written.
  bool get isStreaming;

  /// Whether what is being written the agent took up on its own (a
  /// background task's report, a scheduled prompt), not sent by the user.
  bool get isUnprompted;

  bool get canEditMessages;

  /// The sent message being edited, if any, and what is typed in its place.
  ({int index, ComposerDraft draft})? get editing;
  set editing(({int index, ComposerDraft draft})? value);

  /// [from], where the user wrote it (the originating conversation).
  void editMessage(int index, ComposerMessage message, {UserPlace? from});

  /// Moves what the item at [index] runs to the background; null when it
  /// cannot be.
  VoidCallback? moveToBackgroundAt(int index);

  /// Stops the subagent at [index]; null when it cannot be.
  VoidCallback? stopAt(int index);
}

/// Optional change information from a feed that owns its edits. The revision
/// must change for every edit except text-only replacements and status updates.
/// Changed text rows accumulate until that revision changes, not until read:
/// several windows and throttled frames can observe the feed independently.
abstract interface class ChatFeedTextChanges {
  Object get structureRevision;
  Iterable<int> get textChangedRows;
}
