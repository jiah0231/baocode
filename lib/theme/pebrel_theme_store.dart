import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../platform/data_dir.dart';
import 'pebrel_theme.dart';

/// Local-only storage of explicitly imported Pebrel theme snapshots.
///
/// Documents are data, never code or URLs to fetch. Neither import nor restore
/// transmits their contents. Existing VS Code themes and settings are untouched.
/// Each import gets an opaque identity independent of its display name/path.
class PebrelThemeStore {
  PebrelThemeStore({Directory? directory})
    : directory =
          directory ??
          Directory(p.join(DataDirectory.current.userDir, 'pebrel-themes'));

  static const maxImportBytes = 1024 * 1024;
  static const maxThemes = 128;
  static const _maxStoredBytes = maxImportBytes * 2;
  static const _prefix = 'Pebrel Custom ';
  static final _idPattern = RegExp(r'^Pebrel Custom [0-9a-f]{32}$');
  static final _filePattern = RegExp(r'^[0-9a-f]{32}\.json$');
  static final _queues = <String, Future<void>>{};

  final Directory directory;
  Map<String, PebrelThemeDefinition> _themes = {};
  List<String> _warnings = [];

  Map<String, PebrelThemeDefinition> get themes => Map.unmodifiable(_themes);

  /// Corrupt snapshots stay on disk for recovery, but are never activated.
  /// Messages deliberately omit source paths and document contents.
  List<String> get warnings => List.unmodifiable(_warnings);

  /// Use after load/delete so a removed or corrupt active custom snapshot
  /// falls back without changing a selected built-in or extension theme.
  String resolveSelection(String selected, {required String fallback}) =>
      selected.startsWith(_prefix) && !_themes.containsKey(selected)
      ? fallback
      : selected;

  Future<Map<String, PebrelThemeDefinition>> load() => _serial(() async {
    await _read();
    return themes;
  });

  /// Reads a regular local file with an enforced streaming size limit, even if
  /// it changes after the initial stat. Does not retain the source path.
  Future<String> importFile(File file) async {
    final text = await _readBounded(file, maxImportBytes);
    return importJson(text);
  }

  Future<String> importJson(String text) {
    // Reject before scheduling disk work. The depth check precedes jsonDecode,
    // preventing a tiny but deeply nested document from exhausting the stack.
    final json = _decode(text, maxImportBytes);
    final theme = PebrelThemeDefinition.fromJson(json);
    final name = theme.name.trim().toLowerCase();
    if (name.isEmpty || theme.name.length > 256) {
      throw const FormatException('Theme name must contain 1–256 characters.');
    }
    return _serial(
      () => _locked(() async {
        await _read();
        if (_themes.values.any((t) => t.name.trim().toLowerCase() == name)) {
          throw const FormatException(
            'A custom theme with this name already exists. Rename it before importing.',
          );
        }
        if (_themes.length >= maxThemes) {
          throw const FormatException('The custom theme library is full.');
        }
        final random = Random.secure();
        String token;
        File target;
        do {
          token = List.generate(
            16,
            (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
          target = File(p.join(directory.path, '$token.json'));
        } while (await FileSystemEntity.type(target.path, followLinks: false) !=
            FileSystemEntityType.notFound);
        final id = '$_prefix$token';
        final encoded = jsonEncode({
          'version': 1,
          'id': id,
          'theme': theme.toJson(),
        });
        if (utf8.encode(encoded).length > _maxStoredBytes) {
          throw const FormatException('Theme snapshot is too large.');
        }
        // Same-directory rename is the commit point. Never fall back to writing
        // the destination in place: readers must not see a partial snapshot.
        final temporary = File(p.join(directory.path, '.$token.tmp'));
        var ownsTemporary = false;
        try {
          await temporary.create(exclusive: true);
          ownsTemporary = true;
          await temporary.writeAsString(encoded, flush: true);
          await temporary.rename(target.path);
        } finally {
          if (ownsTemporary && await temporary.exists()) {
            await temporary.delete();
          }
        }
        _themes = {..._themes, id: theme};
        return id;
      }),
    );
  }

  /// Only removes an owned snapshot, never a built-in/theme extension or an
  /// arbitrary path. The caller must reset an active selection to its default
  /// and refresh WorkbenchThemeService after removal (or after a missing load).
  Future<void> delete(String id) => _serial(() async {
    if (!_idPattern.hasMatch(id)) {
      throw const FormatException('Not a custom Pebrel theme identity.');
    }
    if (!await directory.exists()) {
      _themes = {};
      return;
    }
    await _locked(() async {
      final file = File(
        p.join(directory.path, '${id.substring(_prefix.length)}.json'),
      );
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        await file.delete();
      } else if (type != FileSystemEntityType.notFound) {
        throw const FormatException(
          'Custom theme snapshot is not a regular file.',
        );
      }
      await _read();
    });
  });

  Future<void> _read() async {
    final loaded = <String, PebrelThemeDefinition>{};
    final warnings = <String>[];
    if (await directory.exists()) {
      final entries = await directory.list(followLinks: false).toList();
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entry in entries) {
        if (!_filePattern.hasMatch(p.basename(entry.path))) continue;
        if (loaded.length >= maxThemes) {
          warnings.add(
            'Additional custom themes were skipped: library limit reached.',
          );
          break;
        }
        try {
          final data = _decode(
            await _readBounded(File(entry.path), _maxStoredBytes),
            _maxStoredBytes,
          );
          final id = '$_prefix${p.basenameWithoutExtension(entry.path)}';
          if (data['version'] != 1 ||
              data['id'] != id ||
              data['theme'] is! Map<String, dynamic>) {
            throw const FormatException('Invalid snapshot envelope.');
          }
          final theme = PebrelThemeDefinition.fromJson(
            data['theme'] as Map<String, dynamic>,
          );
          if (theme.name.trim().isEmpty || theme.name.length > 256) {
            throw const FormatException('Invalid theme name.');
          }
          loaded[id] = theme;
        } on FormatException {
          warnings.add('An invalid custom theme was skipped.');
        } on FileSystemException {
          warnings.add('An unreadable custom theme was skipped.');
        }
      }
    }
    _themes = loaded;
    _warnings = warnings;
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final key = p.normalize(p.absolute(directory.path));
    final previous = _queues[key] ?? Future<void>.value();
    final result = previous.then((_) => operation());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _queues[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_queues[key], tail)) _queues.remove(key);
      }),
    );
    return result;
  }

  Future<T> _locked<T>(Future<T> Function() operation) async {
    await directory.create(recursive: true);
    final lockFile = File(p.join(directory.path, '.lock'));
    final type = await FileSystemEntity.type(lockFile.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FormatException(
        'Custom theme library lock is not a regular file.',
      );
    }
    final lock = await lockFile.open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      return await operation();
    } finally {
      await lock.close();
    }
  }

  static Future<String> _readBounded(File file, int limit) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('Choose a regular JSON theme file.');
    }
    if (await file.length() > limit) {
      throw const FormatException('Theme file exceeds the 1 MiB import limit.');
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('Theme file is too large.');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes); // Strict UTF-8; malformed bytes are rejected.
  }

  static Map<String, dynamic> _decode(String text, int limit) {
    if (text.length > limit || utf8.encode(text).length > limit) {
      throw const FormatException('Theme file exceeds the 1 MiB import limit.');
    }
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (final unit in text.codeUnits) {
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (unit == 92) {
          escaped = true;
        } else if (unit == 34) {
          inString = false;
        }
      } else if (unit == 34) {
        inString = true;
      } else if (unit == 123 || unit == 91) {
        if (++depth > 64) {
          throw const FormatException('Theme JSON is nested too deeply.');
        }
      } else if (unit == 125 || unit == 93) {
        depth--;
      }
    }
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Theme JSON must be an object.');
    }
    return value;
  }
}
