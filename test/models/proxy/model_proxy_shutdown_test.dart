import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/proxy/model_proxy.dart';
import 'package:baocode/usage/usage_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('close captures usage even while credentials are still pending', () async {
    HttpOverrides.global = null;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient();
    final keyRequested = Completer<void>();
    final key = Completer<String?>();
    final storage = MemoryUsageStorage();
    final ledger = UsageLedger(storage);
    final provider = ModelProvider(
      id: 'test',
      name: 'Test',
      protocol: ProviderProtocol.anthropic,
      baseUrl: 'http://127.0.0.1:${upstream.port}',
      models: const [ProviderModel(id: 'claude-test')],
    );
    final proxy = ModelProxy(
      provider: (_) => provider,
      key: (_) {
        keyRequested.complete();
        return key.future;
      },
      usage: () => ledger,
      token: 'test-token',
    );
    addTearDown(() async {
      client.close(force: true);
      await proxy.close();
      await upstream.close(force: true);
      ledger.dispose();
    });

    final endpoint = await proxy.endpoint('test');
    final request = await client.postUrl(
      Uri.parse('${endpoint.baseUrl}/v1/messages'),
    );
    request.headers.set('x-api-key', endpoint.token);
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'model': 'claude-test',
        'messages': [
          {'role': 'user', 'content': 'Hello'},
        ],
      }),
    );
    // Shutdown can close the downstream connection without an HTTP reply.
    final answered = () async {
      try {
        final response = await request.close();
        await response.drain<void>();
      } on Object {
        // The proxy deliberately aborts the connection on close.
      }
    }();
    await keyRequested.future;
    await proxy.close().timeout(const Duration(seconds: 5));
    await ledger.flushAndWait();
    final calls = await storage.read(await storage.days());
    expect(calls, hasLength(1));
    expect(calls.single.error, contains('closing'));

    key.complete('not-used');
    await answered;
    await ledger.flushAndWait();
    expect(await storage.read(await storage.days()), hasLength(1));

    // close remains reusable: callers may obtain a fresh local endpoint.
    expect((await proxy.endpoint('test')).baseUrl, startsWith('http://127.0.0.1:'));
  });

  test('close interrupts a request still uploading its body', () async {
    HttpOverrides.global = null;
    final proxy = ModelProxy(provider: (_) => null, key: (_) async => null);
    final endpoint = await proxy.endpoint('test');
    final uri = Uri.parse(endpoint.baseUrl);
    final socket = await Socket.connect(uri.host, uri.port);
    addTearDown(() async {
      socket.destroy();
      await proxy.close();
    });
    // A partial body keeps the request decoder waiting on network input.
    socket.write(
      'POST ${uri.path}/v1/messages HTTP/1.1\r\n'
      'Host: localhost\r\n'
      'x-api-key: ${endpoint.token}\r\n'
      'Content-Length: 100000\r\n\r\n{',
    );
    await socket.flush();
    await proxy.close().timeout(const Duration(seconds: 5));
  });

  test('close includes an endpoint bind started in the same turn', () async {
    HttpOverrides.global = null;
    final proxy = ModelProxy(provider: (_) => null, key: (_) async => null);
    addTearDown(proxy.close);
    final opening = proxy.endpoint('test');
    final closing = proxy.close();
    final uri = Uri.parse((await opening).baseUrl);
    await closing;
    await expectLater(
      Socket.connect(
        uri.host,
        uri.port,
        timeout: const Duration(seconds: 2),
      ).then<void>((socket) => socket.destroy()),
      throwsA(isA<SocketException>()),
    );
  });
}
