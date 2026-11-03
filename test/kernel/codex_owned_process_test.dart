import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/kernel/codex/codex_owned_process_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('child output cannot spoof ownership status', () async {
    final helper = _Helper();
    final process = CodexOwnedProcess.forProcess(helper);
    final output = process.stdout.expand((bytes) => bytes).toList();
    final errors = process.stderr.expand((bytes) => bytes).toList();
    var exited = false;
    process.exitCode.then((_) => exited = true);
    helper.output.add(_frame(1, 'job_empty'));
    helper.output.add(_frame(2, 'root_exited:0'));
    helper.output.add(_frame(3, 'root_exited:0'));
    await pumpEventQueue();
    expect(process.rootExitCode, 0);
    expect(process.jobEmpty, isFalse);
    expect(exited, isFalse);
    // Header fragmentation and child output are independent of status.
    final frame = _frame(3, 'job_empty');
    helper.output.add(frame.sublist(0, 2));
    helper.output.add(frame.sublist(2));
    await helper.output.close();
    await helper.errors.close();
    helper.done.complete(0);
    expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
    expect(utf8.decode(await output), 'job_empty');
    expect(utf8.decode(await errors), 'root_exited:0');
    await helper.input.close();
  });

  test('helper death without job acknowledgement remains fail closed', () async {
    final helper = _Helper();
    final process = CodexOwnedProcess.forProcess(helper);
    final output = process.stdout.drain<void>();
    final errors = process.stderr.drain<void>();
    var exited = false;
    process.exitCode.then((_) => exited = true);
    helper.output.add(_frame(3, 'root_exited:0'));
    await helper.output.close();
    await helper.errors.close();
    helper.done.complete(1);
    await Future.wait([output, errors]);
    await pumpEventQueue();
    expect(process.diagnostics['helper_exited'], isTrue);
    expect(process.jobEmpty, isFalse);
    expect(exited, isFalse);
    process.kill();
    await helper.input.done;
    expect(helper.killCalls, 0);
  });

  test('verified pre-resume launch failure completes without replacement risk', () async {
    final helper = _Helper();
    final process = CodexOwnedProcess.forProcess(helper);
    final output = process.stdout.drain<void>();
    final errors = process.stderr.drain<void>();
    helper.output.add(_frame(3, 'launch_failed:assign/5'));
    await helper.output.close();
    await helper.errors.close();
    helper.done.complete(125);
    expect(await process.exitCode.timeout(const Duration(seconds: 5)), 125);
    await Future.wait([output, errors]);
    await helper.input.close();
  });

  for (final bad in ['kind', 'oversize', 'truncated']) {
    test('invalid $bad frame cannot release the writer barrier', () async {
      final helper = _Helper();
      final process = CodexOwnedProcess.forProcess(helper);
      final output = process.stdout.drain<void>();
      final errors = process.stderr.drain<void>();
      var exited = false;
      process.exitCode.then((_) => exited = true);
      if (bad == 'kind') {
        helper.output.add(_frame(9, 'job_empty'));
      } else if (bad == 'oversize') {
        helper.output.add([3, 0, 0, 32, 0]);
      } else {
        helper.output.add([3, 10, 0, 0, 0, 65]);
      }
      if (bad != 'truncated') helper.output.add(_frame(3, 'job_empty'));
      await helper.output.close();
      await helper.errors.close();
      helper.done.complete(0);
      await Future.wait([output, errors]);
      await pumpEventQueue();
      expect(process.stage, 'launcher_protocol_failed');
      expect(exited, isFalse);
      expect(helper.killCalls, 0);
      await helper.input.close();
    });
  }

  test('paused output resumes ordered frames and nonzero root status', () async {
    final helper = _Helper();
    final process = CodexOwnedProcess.forProcess(helper);
    final bytes = <int>[];
    final subscription = process.stdout.listen(bytes.addAll);
    final errors = process.stderr.drain<void>();
    subscription.pause();
    helper.output.add(_frame(1, 'final'));
    helper.output.add(_frame(3, 'root_exited:7'));
    helper.output.add(_frame(3, 'job_empty'));
    helper.done.complete(7);
    await pumpEventQueue();
    expect(bytes, isEmpty);
    expect(process.jobEmpty, isFalse);
    subscription.resume();
    await helper.output.close();
    await helper.errors.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 5)), 7);
    expect(utf8.decode(bytes), 'final');
    expect(process.rootExitCode, 7);
    await subscription.cancel();
    await errors;
    await helper.input.close();
  });

  test('Windows quoting preserves switches and trailing slash in spaced paths', () {
    expect(CodexOwnedProcess.quoteArgument('/d'), '/d');
    expect(CodexOwnedProcess.quoteArgument('%baocode_codex_executable%'),
        '%baocode_codex_executable%');
    expect(CodexOwnedProcess.quoteArgument(''), '""');
    expect(CodexOwnedProcess.quoteArgument('C:\\a b\\'), '"C:\\a b\\\\"');
    expect(CodexOwnedProcess.quoteArgument('a"b'), '"a\\"b"');
  });
}

List<int> _frame(int kind, String body) {
  final data = utf8.encode(body);
  return [kind,
    ...(ByteData(4)..setUint32(0, data.length, Endian.little)).buffer.asUint8List(),
    ...data,
  ];
}

class _Helper implements Process {
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final done = Completer<int>();
  final input = IOSink(StreamController<List<int>>()..stream.listen((_) {}));
  int killCalls = 0;
  @override
  int get pid => 987654321;
  @override
  Future<int> get exitCode => done.future;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  IOSink get stdin => input;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalls++;
    return false;
  }
}
