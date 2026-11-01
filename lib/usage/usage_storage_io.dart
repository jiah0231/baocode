import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'usage_ledger.dart';
import 'usage_record.dart';

/// The calls in [directory]: `<yyyy-MM-dd>.jsonl` a day, and `index.json`.
///
/// Appended to under the file's lock, as the turns' records are (see
/// TurnStatsFiles): another of the app's processes writing at once loses
/// no line. Read off the UI isolate.
class UsageFiles implements UsageStorage {
  UsageFiles(this.directory);

  final String directory;

  // File locks are process-wide on some platforms. Share the queue across
  // instances too, so their isolates cannot overlap a read/modify/write.
  static final Map<String, _UsageQueue> _queues = {};
  late final _UsageQueue _queue = _queues.putIfAbsent(
    p.normalize(p.absolute(directory)),
    _UsageQueue.new,
  );

  @override
  Future<void> drain() => _queue.tail;

  static final _dayFile = RegExp(r'^(\d{4}-\d{2}-\d{2})\.jsonl$');

  File _file(String day) => File(p.join(directory, '$day.jsonl'));
  File get _index => File(p.join(directory, 'index.json'));

  @override
  void append(String day, List<String> lines) {
    if (lines.isEmpty) return;
    final path = _file(day).path;
    final snapshot = List<String>.of(lines);
    _queue.run(() => _appendOffThread(path, snapshot));
  }

  static Future<void> _appendOffThread(String path, List<String> lines) =>
      Isolate.run(() => _append(path, lines));

  static void _append(String path, List<String> lines) {
    final file = File(path);
    try {
      file.parent.createSync(recursive: true);
      final open = file.openSync(mode: FileMode.append);
      try {
        open.lockSync(FileLock.blockingExclusive);
        open
          ..setPositionSync(open.lengthSync())
          ..writeStringSync('${lines.join('\n')}\n')
          ..flushSync();
      } finally {
        open.closeSync();
      }
    } on FileSystemException catch (error) {
      debugPrint('Usage not kept: $error');
    }
  }

  @override
  Future<List<UsageCall>> read(List<String> days) {
    final paths = [for (final day in days) _file(day).path];
    return _queue.run(() => _readOffThread(paths));
  }

  static Future<List<UsageCall>> _readOffThread(List<String> paths) =>
      Isolate.run(() => _readAll(paths));

  static List<UsageCall> _readAll(List<String> paths) {
    final calls = <UsageCall>[];
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        for (final line in const LineSplitter().convert(
          utf8.decode(file.readAsBytesSync(), allowMalformed: true),
        )) {
          if (UsageCall.decode(line) case final call?) calls.add(call);
        }
      } on FileSystemException {
        continue;
      }
    }
    return calls;
  }

  @override
  Future<List<String>> days() async => (await sizes()).keys.toList()..sort();

  @override
  Future<Map<String, int>> sizes() => _queue.run(_sizes);

  Future<Map<String, int>> _sizes() async {
    final folder = Directory(directory);
    final sizes = <String, int>{};
    try {
      if (!await folder.exists()) return sizes;
      await for (final entry in folder.list()) {
        if (entry is! File) continue;
        final match = _dayFile.firstMatch(p.basename(entry.path));
        if (match == null) continue;
        sizes[match.group(1)!] = await entry.length();
      }
    } on FileSystemException {
      // What was read.
    }
    return sizes;
  }

  @override
  Future<void> delete(String day) => _queue.run(() => _delete(day));

  Future<void> _delete(String day) async {
    try {
      await _file(day).delete();
    } on FileSystemException {
      // Gone already.
    }
  }

  @override
  Future<int> rewrite(String day, bool Function(UsageCall call) drop) =>
      _queue.run(() => _rewrite(day, drop));

  Future<int> _rewrite(String day, bool Function(UsageCall call) drop) async {
    final file = _file(day);
    if (!await file.exists()) return 0;
    final open = await file.open(mode: FileMode.append);
    try {
      await open.lock(FileLock.blockingExclusive);
      await open.setPosition(0);
      final bytes = await open.read(await open.length());
      final kept = StringBuffer();
      var dropped = 0;
      for (final line in const LineSplitter().convert(
        utf8.decode(bytes, allowMalformed: true),
      )) {
        final call = UsageCall.decode(line);
        if (call != null && drop(call)) {
          dropped++;
        } else if (line.isNotEmpty) {
          kept.writeln(line);
        }
      }
      if (dropped == 0) return 0;
      await open.truncate(0);
      await open.setPosition(0);
      await open.writeString(kept.toString());
      await open.flush();
      return dropped;
    } finally {
      await open.close();
      if (await file.exists() && await file.length() == 0) {
        await file.delete().catchError((Object _) => file);
      }
    }
  }

  @override
  Future<Map<String, Object?>?> readIndex() => _queue.run(_readIndex);

  Future<Map<String, Object?>?> _readIndex() async {
    try {
      final json = jsonDecode(await _index.readAsString());
      return json is Map<String, Object?> ? json : null;
    } on Object {
      return null;
    }
  }

  @override
  void writeIndex(Map<String, Object?> index) {
    final path = _index.path;
    final snapshot = _snapshot(index) as Map<String, Object?>;
    _queue.run(() => _writeIndexOffThread(path, snapshot));
  }

  static Object? _snapshot(Object? value) => switch (value) {
    Map<String, Object?>() => value.map(
      (key, value) => MapEntry(key, _snapshot(value)),
    ),
    List() => value.map(_snapshot).toList(),
    _ => value,
  };

  static Future<void> _writeIndexOffThread(
    String path,
    Map<String, Object?> index,
  ) => Isolate.run(() => _writeIndex(path, index));

  static void _writeIndex(String path, Map<String, Object?> index) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      // A separate lock survives the atomic replacement of index.json.
      final lock = File('$path.lock').openSync(mode: FileMode.append);
      try {
        lock.lockSync(FileLock.blockingExclusive);
        // Different windows may know different sessions. Preserve the union:
        // stale days in this lookup are harmless (the files decide existence).
        Map<String, Object?>? previous;
        try {
          previous =
              jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        } on Object {
          // A missing or damaged index is rebuilt from this run's entries.
        }
        final sessions = <String, Set<String>>{};
        for (final source in [previous?['s'], index['s']]) {
          if (source is! Map) continue;
          for (final entry in source.entries) {
            final days = entry.value;
            if (days is List) {
              (sessions['${entry.key}'] ??= {}).addAll(
                days.whereType<String>(),
              );
            }
          }
        }
        final merged = {
          ...index,
          's': sessions.map(
            (key, value) => MapEntry(key, value.toList()..sort()),
          ),
        };
        final temp = File('$path.tmp')
          ..writeAsStringSync(jsonEncode(merged), flush: true);
        temp.renameSync(path);
      } finally {
        lock.closeSync();
      }
    } on FileSystemException catch (error) {
      debugPrint('Usage index not kept: $error');
    }
  }
}

/// Orders all access, not just writes: a read or clear after append must
/// observe that append, even while a disk worker is still busy.
class _UsageQueue {
  Future<void> tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = tail.then((_) => action());
    // Do not poison later operations after one failed operation. The caller
    // still observes its result, while enqueued writes report filesystem errors.
    tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        debugPrint('Usage storage operation failed: $error');
      },
    );
    return result;
  }
}

UsageStorage usageStorageIn(String directory) => UsageFiles(directory);
