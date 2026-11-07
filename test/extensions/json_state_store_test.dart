import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/extensions/window/json_state_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// Simulate old timestamp allocations colliding in one clock tick. All I/O
// remains real; only the old pid_timestamp filename scheme is coalesced.
final class _SameTickFiles extends IOOverrides {
  @override
  File createFile(String path) => super.createFile(
    path.replaceFirst(RegExp(r'\.\d+_\d+\.tmp$'), '.same-clock-tick.tmp'),
  );
}

// Pause one real file write without sleeps, so queue ordering and independent
// targets can be observed while that write is definitely still in progress.
final class _ControlledFiles extends IOOverrides {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return p.basename(path) == 'value.tmp' ? _ControlledFile(file, this) : file;
  }
}

final class _ControlledFile implements File {
  _ControlledFile(this.file, this.control);
  final File file;
  final _ControlledFiles control;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    if (contents == 'blocked') {
      control.entered.complete();
      await control.release.future;
    }
    if (contents == 'fail') {
      throw FileSystemException('Injected write failure', file.path);
    }
    return file.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  Future<File> rename(String newPath) => file.rename(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late String path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('json-state-test-');
    path = p.join(directory.path, 'state.json');
  });
  tearDown(() => directory.delete(recursive: true));

  Future<void> expectOnlyDestination() async {
    expect(await directory.list().map((entry) => entry.path).toList(), [path]);
  }

  test(
    'concurrent writes reserve unique temporary paths in one clock tick',
    () async {
      final documents = List.generate(
        32,
        (index) =>
            jsonEncode({'writer': index, 'payload': 'x' * (1024 + index)}),
      );
      await IOOverrides.runWithIOOverrides(
        () => Future.wait([
          for (final document in documents) writeAtomically(path, document),
        ]),
        _SameTickFiles(),
      );
      final result = await File(path).readAsString();
      expect(result, documents.last);
      expect(jsonDecode(result), isA<Map<String, dynamic>>());
      await expectOnlyDestination();
    },
  );

  test('independent stores can flush one destination concurrently', () async {
    final stores = List.generate(
      16,
      (index) => JsonStateStore(path)..set('writer', '$index'),
    );
    try {
      await IOOverrides.runWithIOOverrides(
        () => Future.wait([for (final store in stores) store.flush()]),
        _SameTickFiles(),
      );
      final result = jsonDecode(await File(path).readAsString());
      expect(result, {'writer': '${stores.length - 1}'});
      await expectOnlyDestination();
    } finally {
      await Future.wait([for (final store in stores) store.dispose()]);
    }
  });

  test(
    'rename failure propagates and removes only its own staging files',
    () async {
      await Directory(path).create();
      final marker = File(p.join(path, 'keep.txt'));
      await marker.writeAsString('preserve');
      await expectLater(
        writeAtomically(path, '{"replacement":true}'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await marker.readAsString(), 'preserve');
      await expectOnlyDestination();
    },
  );

  test(
    'same-target aliases are FIFO while another target can finish',
    () async {
      final control = _ControlledFiles();
      final other = p.join(directory.path, 'other.json');
      final alias = p.join(directory.path, 'unused', '..', 'state.json');
      final caseAlias = Platform.isWindows ? path.toUpperCase() : path;
      await IOOverrides.runWithIOOverrides(() async {
        final first = writeAtomically(path, 'blocked');
        await control.entered.future;
        var secondFinished = false;
        final second = writeAtomically(alias, 'second').then((_) {
          secondFinished = true;
        });
        final third = writeAtomically(caseAlias, 'third');
        final fourth = writeAtomically(path, 'last');
        try {
          await writeAtomically(
            other,
            'independent',
          ).timeout(const Duration(seconds: 5));
          expect(await File(other).readAsString(), 'independent');
          expect(secondFinished, isFalse);
          expect(await File(path).exists(), isFalse);
        } finally {
          control.release.complete();
          await Future.wait([first, second, third, fourth]);
        }
      }, control);
      expect(await File(path).readAsString(), 'last');
      expect(
        await directory.list().map((entry) => p.basename(entry.path)).toList(),
        unorderedEquals(['state.json', 'other.json']),
      );
    },
  );

  test(
    'a failed write stays visible and a queued successor still succeeds',
    () async {
      await IOOverrides.runWithIOOverrides(() async {
        final failed = writeAtomically(path, 'fail');
        final observed = expectLater(
          failed,
          throwsA(isA<FileSystemException>()),
        );
        final successor = writeAtomically(path, '{"recovered":true}');
        await Future.wait([observed, successor]);
      }, _ControlledFiles());
      expect(jsonDecode(await File(path).readAsString()), {'recovered': true});
      await expectOnlyDestination();
    },
  );
}
