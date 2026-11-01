import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/main.dart';
import 'package:baocode/usage/usage_ledger.dart';
import 'package:baocode/usage/usage_record.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _DelayedStorage extends MemoryUsageStorage {
  final drained = Completer<void>();
  int drains = 0;

  @override
  Future<void> drain() {
    drains++;
    return drained.future;
  }
}

void main() {
  late UsageLedger previous;
  late UsageLedger ledger;
  late _DelayedStorage storage;

  setUp(() {
    previous = UsageLedger.current;
    storage = _DelayedStorage();
    ledger = UsageLedger(storage);
    UsageLedger.current = ledger;
  });

  tearDown(() {
    if (!storage.drained.isCompleted) storage.drained.complete();
    ledger.dispose();
    UsageLedger.current = previous;
  });

  Future<Workspace> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final workspace = Workspace.mock();
    await tester.pumpWidget(BaoCodeApp(workspace: workspace));
    await tester.pump();
    return workspace;
  }

  testWidgets('accepted quit flushes pending usage and awaits disk writes', (
    tester,
  ) async {
    await pumpApp(tester);
    ledger.record(
      UsageCall(
        at: DateTime(2026, 11, 1),
        duration: const Duration(seconds: 1),
        status: 200,
        provider: 'test',
        model: 'test',
      ),
    );
    expect(storage.lines, isEmpty);

    var exited = false;
    final response = tester.binding.handleRequestAppExit().then((value) {
      exited = true;
      return value;
    });
    await tester.pump();
    expect(storage.drains, 1);
    expect(storage.lines['2026-11-01'], hasLength(1));
    expect(exited, isFalse);
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
    expect(storage.drains, 1);

    storage.drained.complete();
    await tester.pump();
    expect(await response, AppExitResponse.exit);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('cancelled quit does not start the usage shutdown drain', (
    tester,
  ) async {
    final workspace = await pumpApp(tester);
    workspace.selected.session.send(const ComposerMessage(text: 'Go on'));
    await tester.pump();

    final response = tester.binding.handleRequestAppExit();
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(await response, AppExitResponse.cancel);
    expect(storage.drains, 0);

    workspace.selected.session.stop();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('slow saving cancels quit without cancelling the write queue', (
    tester,
  ) async {
    await pumpApp(tester);
    final response = tester.binding.handleRequestAppExit();
    await tester.pump();
    expect(storage.drains, 1);
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Usage data is still saving'), findsOneWidget);
    expect(storage.drained.isCompleted, isFalse);
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
    expect(storage.drains, 1);
    expect(find.text('Usage data is still saving'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(await response, AppExitResponse.cancel);

    storage.drained.complete();
    await tester.pump();
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
    expect(storage.drains, 2);
  });
}
