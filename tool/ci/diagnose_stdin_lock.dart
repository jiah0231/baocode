import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
Future<void> main(List<String> args) async {
  final dir = Directory.systemTemp.createTempSync('usage-lock-probe');
  final path = '${dir.path}/usage.jsonl';
  final process = await Process.start(Platform.resolvedExecutable, ['--disable-dart-dev', File('tool/ci/lock-original-child.dart').absolute.path, path]);
  final errors = process.stderr.transform(utf8.decoder).join();
  final output = StreamIterator(process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
  try {
    if (!await output.moveNext().timeout(const Duration(seconds: 10))) throw StateError('no lock output');
    print('child: ${output.current}; stdout now paused');
    final clock = Stopwatch()..start();
    final write = append(path);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    if (clock.elapsed >= const Duration(seconds: 4)) throw StateError('blocked event loop');
    print('event loop: ${clock.elapsedMilliseconds}ms');
    process.stdin.writeln('release');
    if (args.contains('close')) {
      await process.stdin.close(); print('parent: stdin closed');
    } else { await process.stdin.flush(); print('parent: stdin flushed only'); }
    await write.timeout(const Duration(seconds: 10)); print('parent: write drained');
    final code = await process.exitCode.timeout(const Duration(seconds: 10)); print('parent: exited $code');
    await output.cancel();
    print('stderr: ${await errors}; stored: ${await File(path).readAsLines()}');
  } finally { process.kill(); await output.cancel(); await dir.delete(recursive: true); }
}

Future<void> append(String path) => Isolate.run(() {

      final file = File(path).openSync(mode: FileMode.append);
      try {
        file.lockSync(FileLock.blockingExclusive);
        file.setPositionSync(file.lengthSync());
        file.writeStringSync('after lock\n');
        file.flushSync();
      } finally { file.closeSync(); }

});
