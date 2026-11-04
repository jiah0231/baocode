import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/chrome_sandbox_guard.dart';

const _marker = 'Sandbox cannot access executable';

void main() {
  test('ordinary diagnostics and incomplete or different phrases pass', () {
    for (final output in [
      '',
      'DevTools listening on ws://127.0.0.1:1234/devtools/browser/test\n',
      'Sandbox initialized successfully\n',
      'Sandbox can access executable\n',
      'Sandbox cannot access\n',
      'Sandbox cannot access execution\n',
      'Sandbox cannot\naccess executable\n',
    ]) {
      final guard = ChromeSandboxGuard();
      guard.addOutput('stdout', output);
      guard.addOutput('stderr', output);
      expect(guard.failed, isFalse);
      expect(guard.check, returnsNormally);
    }
  });

  test('known warning fails without a newline and hides paths and logs', () {
    final guard = ChromeSandboxGuard();
    guard.addOutput(
      'stderr',
      '[123:ERROR] $_marker /private/synthetic-user/chrome-secret',
    );
    expect(guard.failed, isTrue);
    expect(guard.retainedOutputCharacters, 0);
    expect(
      guard.check,
      throwsA(
        isA<StateError>()
            .having((error) => error.message, 'message', contains('sandbox'))
            .having(
              (error) => error.toString(),
              'sanitized error',
              allOf(
                isNot(contains('/private/')),
                isNot(contains('chrome-secret')),
                isNot(contains('[123:ERROR]')),
              ),
            ),
      ),
    );
  });

  for (final stream in ['stdout', 'stderr']) {
    test('recognizes every marker split on $stream', () {
      for (var split = 0; split <= _marker.length; split++) {
        final guard = ChromeSandboxGuard();
        guard.addOutput(stream, 'prefix ${_marker.substring(0, split)}');
        expect(guard.failed, split == _marker.length, reason: 'split $split');
        guard.addOutput(stream, '${_marker.substring(split)} suffix');
        expect(guard.failed, isTrue, reason: 'split $split');
      }
    });
  }

  test('recognizes one-character chunks and mixed case', () {
    final guard = ChromeSandboxGuard();
    for (final character in 'sANDBOX cANNOT aCCESS eXECUTABLE'.split('')) {
      guard.addOutput('stderr', character);
    }
    expect(guard.failed, isTrue);
  });

  test('does not join different streams into a false diagnostic', () {
    final guard = ChromeSandboxGuard();
    guard.addOutput('stderr', 'Sandbox cannot ');
    guard.addOutput('stdout', 'access executable');
    expect(guard.failed, isFalse);
    guard.addOutput('stdout', '\nordinary stdout message\n');
    guard.addOutput('stderr', 'access executable');
    expect(guard.failed, isTrue);
  });

  test('retained output stays bounded across large chunks and many writes', () {
    final guard = ChromeSandboxGuard();
    final largeChunk = List.filled(20000, 'x').join();
    final maximum = 2 * (_marker.length - 1);
    for (var index = 0; index < 100; index++) {
      guard.addOutput('stdout', largeChunk);
      guard.addOutput('stderr', largeChunk);
      expect(guard.retainedOutputCharacters, lessThanOrEqualTo(maximum));
    }
    // Crosses an internal scan boundary, with a long suffix after the marker.
    guard.addOutput(
      'stderr',
      '${List.filled(1010, 'x').join()}$_marker$largeChunk',
    );
    expect(guard.failed, isTrue);
    expect(guard.retainedOutputCharacters, 0);
    guard.addOutput('stderr', largeChunk);
    expect(guard.retainedOutputCharacters, 0);
  });

  test('accepts only stdout and stderr without echoing an invalid name', () {
    final guard = ChromeSandboxGuard();
    expect(
      () => guard.addOutput('/private/invalid-stream', _marker),
      throwsA(
        isA<ChromeSandboxFailure>().having(
          (error) => error.toString(),
          'sanitized error',
          isNot(contains('/private/')),
        ),
      ),
    );
    expect(guard.failed, isTrue);
    expect(guard.retainedOutputCharacters, 0);
  });

  test('latches before a synchronous stop callback and invokes it once', () {
    var stops = 0;
    var failedDuringStop = false;
    Object? failureDuringStop;
    late ChromeSandboxGuard guard;
    guard = ChromeSandboxGuard(
      onViolation: () {
        stops++;
        failedDuringStop = guard.failed;
        try {
          guard.check();
        } catch (error) {
          failureDuringStop = error;
        }
        // Re-entrant failure and cleanup errors cannot erase the latch.
        guard.failMonitoring();
        throw StateError('/private/synthetic-cleanup-error');
      },
    );
    expect(() => guard.addOutput('stderr', _marker), returnsNormally);
    expect(stops, 1);
    expect(failedDuringStop, isTrue);
    expect(failureDuringStop, isA<ChromeSandboxFailure>());
    guard.addOutput('stdout', _marker);
    guard.failMonitoring();
    expect(stops, 1);
    expect(
      guard.check,
      throwsA(
        isA<ChromeSandboxFailure>().having(
          (error) => error.message,
          'sticky message',
          'Chrome sandbox failure detected; refusing to continue this test.',
        ),
      ),
    );
    expect(guard.check, throwsA(same(failureDuringStop)));
  });

  test('monitoring failure is sticky, sanitized, and stops immediately', () {
    var stops = 0;
    final guard = ChromeSandboxGuard(onViolation: () => stops++);
    guard.addOutput('stderr', '/private/synthetic-output');
    guard.failMonitoring();
    guard.failMonitoring();
    expect(stops, 1);
    expect(guard.failed, isTrue);
    expect(guard.retainedOutputCharacters, 0);
    expect(guard.check, throwsStateError);
  });

  test('normal operations pass results and original errors', () async {
    final guard = ChromeSandboxGuard();
    expect(await guard.run(() async => 42), 42);
    final original = StateError('synthetic operation error');
    await expectLater(
      guard.run<int>(() => throw original),
      throwsA(same(original)),
    );
    await expectLater(
      guard.run<int>(() => Future<int>.error(original)),
      throwsA(same(original)),
    );
    expect(guard.failed, isFalse);
    expect(await guard.run(() async => 'still usable'), 'still usable');
  });

  test('failure rejects pending operations and blocks new dispatch', () async {
    final guard = ChromeSandboxGuard();
    final pending = Completer<int>();
    final otherPending = Completer<String>();
    final result = guard.run(() => pending.future);
    final otherResult = guard.run(() => otherPending.future);
    final rejected = expectLater(result, throwsStateError);
    final otherRejected = expectLater(otherResult, throwsStateError);
    guard.addOutput('stderr', _marker);
    // Neither operation needs to finish for the guard to reject its result.
    await Future.wait([rejected, otherRejected]);
    expect(pending.isCompleted, isFalse);
    expect(otherPending.isCompleted, isFalse);
    var dispatched = false;
    await expectLater(
      guard.run(() async {
        dispatched = true;
        return 99;
      }),
      throwsStateError,
    );
    expect(dispatched, isFalse);
    pending.complete(42);
    otherPending.complete('late');
    await Future<void>.delayed(Duration.zero);
    await expectLater(result, throwsStateError);
    await expectLater(otherResult, throwsStateError);
  });

  test('monitoring failure also rejects pending work', () async {
    final guard = ChromeSandboxGuard();
    final pending = Completer<void>();
    final rejected = expectLater(
      guard.run(() => pending.future),
      throwsStateError,
    );
    guard.failMonitoring();
    await rejected;
    pending.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test('failure during dispatch overrides success or error', () async {
    for (final throwError in [false, true]) {
      final guard = ChromeSandboxGuard();
      await expectLater(
        guard.run<int>(() {
          guard.addOutput('stderr', _marker);
          if (throwError) {
            throw StateError('/private/operation-error');
          }
          return Future.value(42);
        }),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'guard failure',
            'Chrome sandbox failure detected; refusing to continue this test.',
          ),
        ),
      );
    }
  });

  test('undelivered results cannot outrun the failure latch', () async {
    final guard = ChromeSandboxGuard();
    final pending = Completer<int>();
    final rejected = expectLater(
      guard.run(() => pending.future),
      throwsStateError,
    );
    pending.complete(42);
    guard.addOutput('stderr', _marker);
    await rejected;
  });

  test('idle failures and late errors emit no unhandled error', () async {
    final uncaught = <Object>[];
    final finished = Completer<void>();
    runZonedGuarded(() async {
      try {
        ChromeSandboxGuard().addOutput('stderr', _marker);
        ChromeSandboxGuard().failMonitoring();
        final guard = ChromeSandboxGuard();
        final pending = Completer<int>();
        final rejected = expectLater(
          guard.run(() => pending.future),
          throwsStateError,
        );
        guard.addOutput('stderr', _marker);
        await rejected;
        pending.completeError(StateError('synthetic late error'));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      } catch (error) {
        uncaught.add(error);
      } finally {
        finished.complete();
      }
    }, (error, stack) => uncaught.add(error));
    await finished.future;
    expect(uncaught, isEmpty);
  });
}
