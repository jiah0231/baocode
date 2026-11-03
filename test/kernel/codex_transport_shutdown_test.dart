import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/codex/codex_process_transport_io.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wrapper exit alone does not authorize a replacement writer', () async {
    final home = await Directory.systemTemp.createTemp('codex-shutdown-fixture-');
    final previous = CodexProcessTransport.registry;
    final registry = CodexProcessRegistry(
      file: File('${home.path}/registry.json'),
      lookup: (_) async => null,
      signal: (_) => false,
    );
    CodexProcessTransport.registry = registry;
    final process = _WrapperProcess();
    final transport = CodexProcessTransport.forProcess(
      process,
      windows: true,
      terminateTree: (_, _) async =>
          throw StateError('Must not terminate an already exited root PID'),
    );
    var completed = false;
    final stopped = transport.exited.then((_) => completed = true);
    final received = <Map<String, Object?>>[];
    final subscription = transport.messages.listen(received.add);
    try {
      // A cmd/npm wrapper can terminate while a descendant still owns the
      // protocol pipe and a thread writer. Never turn root exit into success.
      process.done.complete(0);
      await pumpEventQueue();
      expect(completed, isFalse);
      expect(transport.shutdownDiagnostics['root_exited'], isTrue);
      expect(transport.shutdownDiagnostics['stdout_eof_observed'], isFalse);
      expect(transport.shutdownDiagnostics['decoder_drained'], isFalse);
      transport.close();
      await pumpEventQueue();
      expect(completed, isFalse);
      expect(received.where(CodexExit.isExit), isEmpty);

      // Only the fixture's owner releases its descendant and output handle.
      // A late protocol record must still precede the final exit notification.
      process.output.add(utf8.encode('{"id":7,"result":{}}\n'));
      await process.output.close();
      await process.errors.close();
      await stopped.timeout(const Duration(seconds: 5));
      expect(completed, isTrue);
      expect(transport.shutdownDiagnostics['stdout_eof_observed'], isTrue);
      expect(transport.shutdownDiagnostics['decoder_drained'], isTrue);
      expect(transport.shutdownDiagnostics['messages_drained'], isTrue);
      expect(received.first['id'], 7);
      expect(received.where(CodexExit.isExit), hasLength(1));
      expect(CodexExit.isExit(received.last), isTrue);
    } finally {
      await subscription.cancel();
      if (!process.output.isClosed) await process.output.close();
      if (!process.errors.isClosed) await process.errors.close();
      if (!process.done.isCompleted) process.done.complete(0);
      await process.input.close();
      await registry.flush();
      CodexProcessTransport.registry = previous;
      await home.delete(recursive: true);
    }
  });
  for (final mode in ['nonzero', 'timeout', 'unavailable', 'success', 'grace_exit']) {
    test('Windows termination $mode is not writer release', () async {
      final home = await Directory.systemTemp.createTemp('codex-close-test-');
      final previous = CodexProcessTransport.registry;
      final registry = CodexProcessRegistry(
        file: File('${home.path}/registry.json'),
        lookup: (_) async => null,
        signal: (_) => false,
      );
      CodexProcessTransport.registry = registry;
      final process = _WrapperProcess();
      var calls = 0;
      final transport = CodexProcessTransport.forProcess(
        process,
        windows: true,
        shutdownGrace: mode == 'grace_exit'
            ? const Duration(seconds: 1)
            : Duration.zero,
        terminationTimeout: Duration.zero,
        terminateTree: (_, _) async {
          calls++;
          if (mode == 'timeout') return Completer<ProcessResult>().future;
          if (mode == 'unavailable') throw ProcessException('taskkill', []);
          return ProcessResult(process.pid, mode == 'success' ? 0 : 5, '', 'not logged');
        },
      );
      final subscription = transport.messages.listen((_) {});
      var completed = false;
      final stopped = transport.exited.then((_) => completed = true);
      try {
        transport.close();
        transport.close();
        if (mode == 'grace_exit') process.done.complete(0);
        await pumpEventQueue();
        expect(calls, mode == 'grace_exit' ? 0 : 1);
        expect(completed, isFalse);
        expect(transport.shutdownDiagnostics['termination'], {
          'success': 'tree_termination_command_succeeded',
          'grace_exit': 'root_exited_before_tree_termination',
          'nonzero': 'tree_termination_failed_5',
          'timeout': 'tree_termination_timeout_outcome_unknown',
          'unavailable': 'tree_termination_unavailable',
        }[mode]);
        if (!process.done.isCompleted) process.done.complete(0);
        await pumpEventQueue();
        transport.close();
        expect(calls, mode == 'grace_exit' ? 0 : 1,
            reason: 'Never retry PID cleanup after root exit');
        expect(completed, isFalse);
        await process.output.close();
        await process.errors.close();
        await stopped.timeout(const Duration(seconds: 5));
      } finally {
        await subscription.cancel();
        if (!process.done.isCompleted) process.done.complete(0);
        if (!process.output.isClosed) await process.output.close();
        if (!process.errors.isClosed) await process.errors.close();
        await stopped.timeout(const Duration(seconds: 5));
        await process.input.close();
        await registry.flush();
        CodexProcessTransport.registry = previous;
        await home.delete(recursive: true);
      }
    });
  }

}

/// A wrapper and its inherited output pipe have deliberately independent
/// lifetimes. No OS processes, user homes, credentials, or model calls are used.
class _WrapperProcess implements Process {
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final done = Completer<int>();
  final input = IOSink(StreamController<List<int>>()..stream.listen((_) {}));

  @override
  int get pid => 987654320;
  @override
  Future<int> get exitCode => done.future;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  IOSink get stdin => input;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
}
