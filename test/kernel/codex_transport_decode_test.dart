import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/codex/codex_json_decode_io.dart';
import 'package:baocode/kernel/codex/codex_process_transport_io.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('small messages do not start a decoding worker', () {
    final result = decodeCodexJson('{"id":1}', decodeLarge: (_) {
      fail('Small messages should not pay for an isolate');
    });
    expect(result, {'id': 1});
  });

  test('ordered decoding waits for a large line before later messages', () async {
    final gate = Completer<Object?>();
    final values = <Object?>[];
    final complete = Stream.fromIterable(['{"id":1}', '{}'])
        .asyncMap((line) => decodeCodexJson(
          line,
          offloadAt: 5,
          decodeLarge: (_) => gate.future,
        ))
        .forEach(values.add);
    await pumpEventQueue();
    expect(values, isEmpty);
    gate.complete({'id': 1});
    await complete;
    expect(values, [{'id': 1}, <String, Object?>{}]);
  });

  test('large JSON remains complete and malformed JSON reports an error', () async {
    final text = List.filled(70000, 'x').join();
    expect(await decodeCodexJson(jsonEncode({'text': text})), {'text': text});
    await expectLater(
      Future.sync(() => decodeCodexJson('$text{')),
      throwsFormatException,
    );
  });

  test('process exit follows the last decoded stdout messages', () async {
    final directory = await Directory.systemTemp.createTemp('codex-decode-');
    final previous = CodexProcessTransport.registry;
    CodexProcessTransport.registry = CodexProcessRegistry(
      file: File('${directory.path}/registry.json'),
      lookup: (_) async => null,
      signal: (_) => false,
    );
    final process = _Process();
    final transport = CodexProcessTransport.forProcess(process);
    final received = <Map<String, Object?>>[];
    final drained = transport.messages.forEach(received.add);
    try {
      final text = List.filled(70000, 'x').join();
      process.output.add(utf8.encode('${jsonEncode({'id': 1, 'text': text})}\n'));
      process.output.add(utf8.encode('not JSON\n{"id":2}\n'));
      unawaited(process.output.close());
      unawaited(process.errors.close());
      process.done.complete(0);
      await transport.exited;
      await drained;
      expect(received, hasLength(3));
      expect(received[0], {'id': 1, 'text': text});
      expect(received[1], {'id': 2});
      expect(CodexExit.isExit(received[2]), isTrue);
      expect(received[2]['stderr'], contains('not JSON'));
    } finally {
      await CodexProcessTransport.registry.flush();
      CodexProcessTransport.registry = previous;
      await process.input.close();
      await directory.delete(recursive: true);
    }
  });
  test('exit completes without any messages subscriber', () async {
    final directory = await Directory.systemTemp.createTemp('codex-no-listener-');
    final previous = CodexProcessTransport.registry;
    CodexProcessTransport.registry = CodexProcessRegistry(
      file: File('${directory.path}/registry.json'),
      lookup: (_) async => null,
      signal: (_) => false,
    );
    final process = _Process();
    final transport = CodexProcessTransport.forProcess(process);
    try {
      process.output.add(utf8.encode('{"id":1}\n'));
      unawaited(process.output.close());
      unawaited(process.errors.close());
      process.done.complete(0);
      await transport.exited.timeout(const Duration(seconds: 5));
    } finally {
      await CodexProcessTransport.registry.flush();
      CodexProcessTransport.registry = previous;
      await process.input.close();
      await directory.delete(recursive: true);
    }
  });

}

class _Process implements Process {
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final done = Completer<int>();
  final input = IOSink(StreamController<List<int>>()..stream.listen((_) {}));

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
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
