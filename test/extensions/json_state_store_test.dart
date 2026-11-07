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
      expect(documents, contains(result));
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
      expect([
        for (var index = 0; index < stores.length; index++)
          {'writer': '$index'},
      ], contains(result));
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
}
