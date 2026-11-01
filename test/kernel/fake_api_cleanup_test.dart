import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('graceful FakeApi close waits for an accepted fragmented body', () async {
    final api = await FakeApi.start(script: [Reply.text('finished')]);
    final uri = Uri.parse(api.baseUrl);
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, uri.port);
    final response = <int>[];
    final received = Completer<void>();
    final subscription = socket.listen(
      response.addAll,
      onDone: received.complete,
    );
    try {
      final body = utf8.encode(
        jsonEncode({
          'model': 'fixture-model',
          'system': 'You are an agent',
          'messages': [
            {'role': 'user', 'content': 'test'},
          ],
          'max_tokens': 10,
          'stream': true,
        }),
      );
      socket.write(
        'POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n',
      );
      socket.add(body.sublist(0, body.length - 1));
      await socket.flush();
      final deadline = Stopwatch()..start();
      while (api.headers.isEmpty) {
        if (deadline.elapsed > const Duration(seconds: 3)) {
          fail('The loopback fixture did not accept the request');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      var closed = false;
      final closing = api.close(force: false).then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, false, reason: 'The accepted body is still incomplete');
      socket.add(body.sublist(body.length - 1));
      await socket.flush();
      await closing.timeout(const Duration(seconds: 3));
      expect(closed, true);
      expect(api.model.requests, hasLength(1));
      await received.future.timeout(const Duration(seconds: 3));
      expect(utf8.decode(response), contains('finished'));
      // Completion is tied to response.close(), not a timer or swallowed error.
    } finally {
      socket.destroy();
      await subscription.cancel();
      await api.close();
    }
  });
}
