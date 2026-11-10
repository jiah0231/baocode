
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
