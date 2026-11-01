import 'dart:async';

import 'package:baocode/kernel/codex/codex_goals.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> goal([
  String status = 'active',
  String thread = 'thread',
]) => {
  'threadId': thread,
  'objective': 'Pass the tests',
  'status': status,
  'createdAt': 1700000000,
  'timeUsedSeconds': 12,
  'tokensUsed': 42,
};

void main() {
  test('only the native complete status means met', () {
    for (final status in [
      'active',
      'paused',
      'blocked',
      'usageLimited',
      'budgetLimited',
    ]) {
      final parsed = CodexGoals.parse(goal(status))!;
      expect(parsed.state, GoalState.active);
      expect(parsed.lastReason, isNotEmpty);
      expect(parsed.checks, 0);
    }
    final complete = CodexGoals.parse(goal('complete'))!;
    expect(complete.state, GoalState.met);
    expect(complete.tokens, 42);
    expect(complete.duration, const Duration(seconds: 12));
    expect(complete.setAt!.millisecondsSinceEpoch, 1700000000000);
    expect(CodexGoals.parse(goal('unknown')), isNull);
  });

  test(
    'explicit control commands use native RPC and user provenance',
    () async {
      final sent = <(String, Map<String, Object?>)>[];
      final reported = <KernelGoal?>[];
      final goals = CodexGoals(
        request: (method, params) async {
          sent.add((method, params));
          return method.endsWith('/clear')
              ? {'cleared': true}
              : {'goal': goal()};
        },
        report: reported.add,
      )..attach('thread');
      await goals.execute('/goal Pass the tests');
      expect(sent.last.$1, 'thread/goal/set');
      expect(sent.last.$2, {
        'threadId': 'thread',
        'origin': 'user',
        'objective': 'Pass the tests',
        'status': 'active',
      });
      await goals.execute('/goal pause');
      expect(sent.last.$2, {
        'threadId': 'thread',
        'origin': 'user',
        'status': 'paused',
      });
      await goals.execute('/goal resume');
      expect(sent.last.$2['status'], 'active');
      await goals.execute('/goal status');
      expect(sent.last.$1, 'thread/goal/get');
      await goals.execute('/goal clear');
      expect(sent.last.$1, 'thread/goal/clear');
      expect(sent.last.$2, {'threadId': 'thread', 'origin': 'user'});
      expect(reported.last, isNull);
    },
  );

  test(
    'late snapshot cannot overwrite a native update or another thread',
    () async {
      final pending = Completer<Map<String, Object?>>();
      final goals = CodexGoals(
        request: (_, _) => pending.future,
        report: (_) {},
      )..attach('thread');
      final refresh = goals.refresh();
      expect(
        goals.notification('thread/goal/updated', {
          'threadId': 'thread',
          'goal': goal('complete'),
        }),
        isTrue,
      );
      pending.complete({'goal': goal()});
      await refresh;
      expect(goals.current!.state, GoalState.met);
      goals.attach('other');
      goals.notification('thread/goal/updated', {
        'threadId': 'thread',
        'goal': goal(),
      });
      expect(goals.current, isNull);
    },
  );

  test(
    'clear confirms no goal even if server had already cleared it',
    () async {
      final goals = CodexGoals(
        request: (_, _) async => {'cleared': false},
        report: (_) {},
      )..attach('thread');
      goals.notification('thread/goal/updated', {
        'threadId': 'thread',
        'goal': goal(),
      });
      await goals.execute('/goal clear');
      expect(goals.current, isNull);
    },
  );

  test('cleared event clears goal, foreign clear does not', () {
    final goals = CodexGoals(request: (_, _) async => {}, report: (_) {})
      ..attach('thread');
    goals.notification('thread/goal/updated', {
      'threadId': 'thread',
      'goal': goal(),
    });
    goals.notification('thread/goal/cleared', {'threadId': 'other'});
    expect(goals.current, isNotNull);
    goals.notification('thread/goal/cleared', {'threadId': 'thread'});
    expect(goals.current, isNull);
  });

  test(
    'older server read is optional; explicit command error is visible',
    () async {
      final goals = CodexGoals(
        request: (_, _) async => throw StateError('method not found'),
        report: (_) {},
      )..attach('thread');
      await goals.refresh();
      await expectLater(goals.execute('/goal test'), throwsStateError);
      expect(CodexGoals.isCommand('/goalish'), isFalse);
      expect(CodexGoals.isCommand('/goal pause'), isTrue);
    },
  );
}
