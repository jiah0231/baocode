@TestOn('browser')
library;

import 'package:baocode/base/step_clock.dart';
import 'package:baocode/chat/widgets/step_header.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('running step obeys reduced motion and ticker mode', (
    tester,
  ) async {
    Future<void> show({bool still = false, bool tickers = true}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(disableAnimations: still),
                child: TickerMode(
                  enabled: tickers,
                  child: const StepHeader(
                    verb: 'Running',
                    object: '示例任务',
                    running: true,
                  ),
                ),
              ),
            ),
          ),
        );

    StepClock shimmerClock() {
      final shimmer = find.descendant(
        of: find.byType(StepHeader),
        matching: find.byWidgetPredicate(
          (widget) => widget is AnimatedBuilder && widget.animation is StepClock,
        ),
      );
      return tester.widget<AnimatedBuilder>(shimmer).animation as StepClock;
    }

    await show();
    expect(find.text('Running 示例任务'), findsOneWidget);
    final clock = shimmerClock();
    expect(clock.step, StepClock.frame);
    expect(clock.isRunning, isTrue);
    final before = clock.ticks;
    await tester.pump(const Duration(milliseconds: 100));
    expect(clock.ticks, greaterThan(before));

    await show(still: true);
    expect(shimmerClock(), same(clock));
    expect(clock.isRunning, isFalse);
    final still = clock.ticks;
    await tester.pump(const Duration(milliseconds: 100));
    expect(clock.ticks, still);
    expect(find.text('Running 示例任务'), findsOneWidget);

    await show(tickers: false);
    expect(clock.isRunning, isFalse);
    await show();
    expect(clock.isRunning, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(clock.isRunning, isFalse);
    expect(tester.takeException(), isNull);
  });
}
