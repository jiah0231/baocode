import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('baocode-lock-proof');
  final child = File('tool/ci/lock-original-child.dart').absolute;
  try {
    for (final closeInput in [false, true]) {
      final process = await Process.start(Platform.resolvedExecutable, [
        '--disable-dart-dev',
        child.path,
        '${directory.path}/$closeInput.jsonl',
      ]);
      final locked = Completer<void>();
      final released = Completer<void>();
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stdout.writeln('closeInput=$closeInput child=$line');
            if (line == 'locked') locked.complete();
            if (line == 'released') released.complete();
          });
      final errors = process.stderr.transform(utf8.decoder).join();
      try {
        await locked.future.timeout(const Duration(seconds: 8));
        process.stdin.writeln('release');
        if (closeInput) {
          await process.stdin.close();
        } else {
          await process.stdin.flush();
        }
        await released.future.timeout(const Duration(seconds: 8));
        try {
          final code = await process.exitCode.timeout(
            const Duration(seconds: 3),
          );
          stdout.writeln('closeInput=$closeInput exit=$code');
          if (code != 0) throw StateError(await errors);
        } on TimeoutException {
          if (closeInput) rethrow;
          stdout.writeln(
            'PROVEN: original child released lock but cannot exit while parent stdin remains open',
          );
          await process.stdin.close();
          final code = await process.exitCode.timeout(
            const Duration(seconds: 3),
          );
          if (code != 0) throw StateError(await errors);
          stdout.writeln(
            'PROVEN: delivering EOF unblocks original child exit=$code',
          );
        }
      } finally {
        process.kill();
        await output.cancel();
      }
    }
  } finally {
    await directory.delete(recursive: true);
  }
}
