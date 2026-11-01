import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/usage/usage_storage_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory folder;
  late UsageFiles files;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('usage-queue');
    files = UsageFiles(folder.path);
  });

  tearDown(() async {
    await files.drain();
    await folder.delete(recursive: true);
  });

  test('append enqueues without disk work and snapshots its input', () async {
    final lines = ['first'];
    files.append('2026-11-01', lines);
    // No lock or disk write may run synchronously on the calling isolate.
    expect(File('${folder.path}/2026-11-01.jsonl').existsSync(), isFalse);
    lines[0] = 'changed after enqueue';
    await files.drain();
    expect(await File('${folder.path}/2026-11-01.jsonl').readAsLines(), [
      'first',
    ]);
  });

  test('instances share write ordering and sizes waits for writes', () async {
    final other = UsageFiles(folder.path);
    for (var i = 0; i < 12; i++) {
      (i.isEven ? files : other).append('2026-11-01', ['$i']);
    }
    expect((await other.sizes()).keys, ['2026-11-01']);
    expect(await File('${folder.path}/2026-11-01.jsonl').readAsLines(), [
      for (var i = 0; i < 12; i++) '$i',
    ]);
  });

  test('clear stays between earlier and later appends', () async {
    files.append('2026-11-01', ['before']);
    final deleted = files.delete('2026-11-01');
    files.append('2026-11-01', ['after']);
    await deleted;
    await files.drain();
    expect(await File('${folder.path}/2026-11-01.jsonl').readAsLines(), [
      'after',
    ]);
  });

  test(
    'index writes snapshot nested values and preserve other sessions',
    () async {
      final days = ['2026-11-01'];
      files.writeIndex({
        'v': 1,
        's': {'a': days},
      });
      days.add('2099-01-01');
      final other = UsageFiles(folder.path);
      other.writeIndex({
        'v': 1,
        's': {
          'b': ['2026-11-02'],
        },
      });
      expect(await other.readIndex(), {
        'v': 1,
        's': {
          'a': ['2026-11-01'],
          'b': ['2026-11-02'],
        },
      });
      // Atomic replacement leaves valid JSON and no unfinished temporary file.
      expect(
        jsonDecode(await File('${folder.path}/index.json').readAsString()),
        await files.readIndex(),
      );
      expect(File('${folder.path}/index.json.tmp').existsSync(), isFalse);
    },
  );

  test('failed writes do not poison later queued writes', () async {
    final blocked = File('${folder.path}/blocked')..writeAsStringSync('file');
    final unavailable = UsageFiles(blocked.path);
    unavailable.append('2026-11-01', ['cannot write']);
    await unavailable.drain();
    await blocked.delete();
    await Directory(blocked.path).create();
    unavailable.append('2026-11-01', ['recovered']);
    await unavailable.drain();
    expect(
      await File('${blocked.path}/2026-11-01.jsonl').readAsLines(),
      ['recovered'],
    );
  });

  test('a disk lock does not block the caller event loop', () async {
    final path = '${folder.path}/2026-11-01.jsonl';
    final script = File('${folder.path}/hold_lock.dart');
    await script.writeAsString(r"""
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  final file = File(args.single).openSync(mode: FileMode.append);
  file.lockSync(FileLock.blockingExclusive);
  stdout.writeln('locked');
  // Always release, even if a regressed synchronous append blocks the test.
  final release = Completer<void>();
  final timer = Timer(const Duration(seconds: 5), () => release.complete());
  final input = stdin.listen((_) {
    if (!release.isCompleted) release.complete();
  });
  await release.future;
  timer.cancel();
  file.closeSync();
  stdout.writeln('released');
  await input.cancel();
}
""");
    final process = await Process.start(_dartExecutable(), [
      '--disable-dart-dev',
      script.path,
      path,
    ]);
    addTearDown(() => process.kill());
    final errors = process.stderr.transform(utf8.decoder).join();
    final output = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    expect(await output.moveNext(), isTrue);
    expect(output.current, 'locked');
    final clock = Stopwatch()..start();
    files.append('2026-11-01', ['after lock']);
    // A caller-side blocking lock would hold both append and this timer until
    // the child's five-second failsafe. No throughput/fps claim is made.
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(clock.elapsed, lessThan(const Duration(seconds: 4)));
    process.stdin.writeln('release');
    await process.stdin.flush();
    await files.drain();
    expect(await process.exitCode, 0, reason: await errors);
    await output.cancel();
    expect(await File(path).readAsLines(), ['after lock']);
  });

}


// flutter test runs flutter_tester rather than dart. Both executables live
// under the SDK's cache; find its Dart VM without relying on a PATH command.
String _dartExecutable() {
  final suffix = Platform.isWindows ? '.exe' : '';
  final executable = File(Platform.resolvedExecutable);
  if (executable.uri.pathSegments.last == 'dart$suffix') return executable.path;
  var directory = executable.parent;
  for (var depth = 0; depth < 7; depth++) {
    final dart = File('${directory.path}/dart-sdk/bin/dart$suffix');
    if (dart.existsSync()) return dart.path;
    directory = directory.parent;
  }
  throw StateError('Cannot find the Flutter SDK Dart VM for the lock fixture');
}
