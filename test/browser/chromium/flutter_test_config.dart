// Keep native Workspace and kernel fixtures out of the Web test compiler.
import 'dart:async';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await testMain();
}
