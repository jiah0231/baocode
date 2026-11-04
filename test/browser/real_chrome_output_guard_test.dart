// Synthetic lifecycle coverage of the actual real-Chrome fixture's output
// monitor. No test in this file starts a process, server, socket or browser.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/chrome_sandbox_guard.dart';
import 'fixtures/real_chrome_fixture.dart';

void main() {
  test('normal output drains before fixture closure succeeds', () async {
    final harness = _OutputHarness();
    harness.stdout.add(utf8.encode('DevTools listening on a fixture endpoint\n'));
    harness.stderr.add(utf8.encode('A benign sandbox status message\n'));
    expect(await harness.fixture.guardedOperationForTesting(() async => 42), 42);
    final closing = harness.fixture.close();
    await harness.endOutput();
    await closing;
    expect(harness.stops, 0);
    expect(harness.fixture.errors, isEmpty);
  });

  test('segmented denial stops fixture and rejects pending and new work', () async {
    final harness = _OutputHarness();
    final reply = Completer<int>();
    var dispatched = 0;
    final pending = harness.fixture.guardedOperationForTesting(() {
      dispatched++;
      return reply.future;
    });
    final rejected = expectLater(pending, throwsA(isA<ChromeSandboxFailure>()));
    harness.stderr.add(utf8.encode('[ERROR] Sandbox cannot access exe'));
    harness.stdout.add(utf8.encode('DevTools listening\n'));
    harness.stderr.add(utf8.encode('cutable C:\\synthetic-secret\\chrome.exe'));
    // Sync stream controllers exercise the real output listener synchronously.
    expect(harness.stops, 1);
    await rejected;
    reply.complete(123); // A late successful CDP result cannot revive the run.
    await expectLater(harness.fixture.guardedOperationForTesting(() async {
      dispatched++;
      return 456;
    }), throwsA(isA<ChromeSandboxFailure>()));
    expect(dispatched, 1);
    await expectLater(harness.fixture.connectNative(), throwsA(isA<ChromeSandboxFailure>()));
    expect(harness.fixture.errors.join(), isNot(contains('synthetic-secret')));
    await harness.endOutput();
    await expectLater(harness.fixture.close(), throwsA(isA<ChromeSandboxFailure>()));
    expect(harness.stops, 1);
  });

  test('denial prevents actual fixture event forwarding and frame ACK work', () async {
    final harness = _OutputHarness();
    harness.fixture.acceptCdpEventForTesting({'method': 'Page.loadEventFired'});
    expect(harness.fixture.events, hasLength(1));
    harness.stderr.add(utf8.encode('Sandbox cannot access executable'));
    harness.fixture.acceptCdpEventForTesting({
      'method': 'Page.screencastFrame',
      'params': {'sessionId': 77},
    });
    harness.fixture.suppressScreencastFrames = true;
    harness.fixture.acceptCdpEventForTesting({
      'method': 'Page.screencastFrame',
      'params': {'sessionId': 78},
    });
    expect(harness.fixture.events, hasLength(1));
    expect(harness.fixture.forwardedScreencastFrames, 0);
    expect(harness.fixture.suppressedScreencastFrames, 0);
    expect(harness.fixture.commands, isEmpty);
    await harness.endOutput();
    await expectLater(harness.fixture.close(), throwsA(isA<ChromeSandboxFailure>()));
  });

  test('denial delivered during close invalidates an otherwise successful run', () async {
    final harness = _OutputHarness();
    expect(await harness.fixture.guardedOperationForTesting(() async => true), isTrue);
    final closed = harness.fixture.close();
    final rejected = expectLater(closed, throwsA(isA<ChromeSandboxFailure>()));
    harness.stderr.add(utf8.encode('Sandbox cannot access executable'));
    await harness.endOutput();
    await rejected;
    expect(harness.stops, 1);
  });

  test('premature pipe EOF rejects work while the other pipe remains open', () async {
    final harness = _OutputHarness();
    final reply = Completer<int>();
    final rejected = expectLater(
      harness.fixture.guardedOperationForTesting(() => reply.future),
      throwsA(isA<ChromeSandboxFailure>()),
    );
    await harness.stdout.close();
    expect(harness.stops, 1);
    await rejected;
    reply.complete(42);
    await harness.stderr.close();
    await expectLater(harness.fixture.close(), throwsA(isA<ChromeSandboxFailure>()));
  });

  test('stream error fails closed without copying raw error contents', () async {
    final harness = _OutputHarness();
    harness.stderr.addError(StateError('synthetic private path'));
    expect(harness.stops, 1);
    expect(harness.fixture.errors.join(), isNot(contains('private path')));
    await harness.endOutput();
    await expectLater(harness.fixture.close(), throwsA(isA<ChromeSandboxFailure>()));
  });

  test('invalid UTF-8 cannot disable monitoring and let the test pass', () async {
    final harness = _OutputHarness();
    harness.stderr.add([0xff]);
    expect(harness.stops, 1);
    await harness.endOutput();
    await expectLater(harness.fixture.close(), throwsA(isA<ChromeSandboxFailure>()));
  });

  test('unfinished output is bounded and fails closed', () async {
    final harness = _OutputHarness();
    await expectLater(harness.fixture.close(), throwsA(isA<ChromeSandboxFailure>()));
    expect(harness.stops, 1);
    await harness.endOutput();
  });

  test('output test seam cannot be reused to reset a failed fixture', () async {
    final harness = _OutputHarness();
    harness.stderr.add(utf8.encode('Sandbox cannot access executable'));
    expect(() => harness.fixture.monitorOutputForTesting(
      const Stream.empty(), const Stream.empty(), stopOwnedProcess: () {},
    ), throwsA(isA<StateError>()));
    await harness.endOutput();
    await expectLater(harness.fixture.close(), throwsA(isA<ChromeSandboxFailure>()));
  });
}

class _OutputHarness {
  _OutputHarness() {
    fixture.monitorOutputForTesting(stdout.stream, stderr.stream,
        stopOwnedProcess: () { stops++; });
  }

  // These paths are deliberately unused. The fixture constructor does not
  // create directories or perform HTTP/Chrome I/O.
  final fixture = RealChromeFixture(
    Directory('unused-synthetic-root'), Uri.parse('http://127.0.0.1/unused'),
  );
  final stdout = StreamController<List<int>>(sync: true);
  final stderr = StreamController<List<int>>(sync: true);
  var stops = 0;

  Future<void> endOutput() async {
    await Future.wait([stdout.close(), stderr.close()]);
  }
}
