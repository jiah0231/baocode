import 'dart:io';

import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/proxy/model_proxy.dart';
import 'package:baocode/models/upstream.dart';
import 'package:flutter_test/flutter_test.dart';

import 'model_proxy_test.dart' show FakeUpstream, post;

void main() {
  setUp(() {
    // These tests exercise real loopback sockets, not the widget binding's
    // HttpClient mock, which returns 400 without reaching either server.
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
  });

  for (final go in [false, true]) {
    for (final protocol in [
      ProviderProtocol.anthropic,
      ProviderProtocol.openaiChat,
      ProviderProtocol.openaiResponses,
    ]) {
      for (final route in ['messages', 'responses']) {
        test('${go ? 'Go' : 'Zen'} ${protocol.name} through $route keeps '
            'session headers private and omits empty tools', () async {
          final upstream = await FakeUpstream.start();
          final provider = ModelProvider(
            id: 'oc',
            name: 'OpenCode',
            protocol: protocol,
            baseUrl: 'http://opencode.ai/zen${go ? '/go' : ''}/v1',
          );
          final proxy = ModelProxy(
            provider: (_) => provider,
            key: (_) async => 'synthetic-key',
            findProxy: (_) => 'PROXY ${Uri.parse(upstream.base).authority}',
            token: 'synthetic-token',
          );
          addTearDown(() async {
            await proxy.close();
            await upstream.close();
          });
          upstream.reply = (_) => (
            200,
            switch (protocol) {
              ProviderProtocol.anthropic => const [
                'event: message_stop',
                'data: {"type":"message_stop"}',
                '',
              ],
              ProviderProtocol.openaiChat => const ['data: [DONE]', ''],
              _ => const [
                'data: {"type":"response.completed","response":{"id":"r1","output":[],"usage":{}}}',
                '',
              ],
            },
          );
          final answer = await post(
            Uri.parse('${(await proxy.endpoint('oc')).baseUrl}/v1/$route'),
            {
              'model': 'deepseek-v4.1-flash',
              'stream': true,
              'tools': [],
              if (route == 'responses')
                'input': 'hello'
              else
                'messages': [
                  {'role': 'user', 'content': 'hello'},
                ],
            },
            headers: {
              'authorization': 'Bearer synthetic-token',
              for (final name in openCodeUntold) name: 'original-session',
            },
          );
          expect(answer.status, 200, reason: answer.text);
          final sent = upstream.requests.single;
          expect((sent.body! as Map).containsKey('tools'), isFalse);
          for (final name in openCodeUntold) {
            if (go && name == openCodeSessionHeader) {
              expect(sent.headers[name], openCodeSession('original-session'));
            } else {
              expect(sent.headers.containsKey(name), isFalse, reason: name);
            }
          }
          // Cleanup must still drain accepted requests after either CLI route.
          await proxy.drainRequests();
        });
      }
    }
  }

  test(
    'Codex Responses keeps populated tools and other providers empty tools',
    () async {
      final upstream = await FakeUpstream.start();
      var provider = ModelProvider(
        id: 'oc',
        name: 'OpenCode',
        protocol: ProviderProtocol.openaiResponses,
        baseUrl: 'http://opencode.ai/zen/v1',
      );
      final proxy = ModelProxy(
        provider: (_) => provider,
        key: (_) async => null,
        findProxy: (_) => 'PROXY ${Uri.parse(upstream.base).authority}',
        token: 'synthetic-token',
      );
      addTearDown(() async {
        await proxy.close();
        await upstream.close();
      });
      final uri = Uri.parse(
        '${(await proxy.endpoint('oc')).baseUrl}/v1/responses',
      );
      const tools = [
        {
          'type': 'function',
          'name': 'read',
          'parameters': {'type': 'object'},
        },
      ];
      final populated = await post(
        uri,
        {'model': 'm', 'input': 'hello', 'tools': tools},
        headers: {'authorization': 'Bearer synthetic-token'},
      );
      expect(populated.status, 200, reason: populated.text);
      expect((upstream.requests.single.body! as Map)['tools'], tools);
      provider = provider.copyWith(baseUrl: 'http://other.example/v1');
      final empty = await post(
        uri,
        {'model': 'm', 'input': 'hello', 'tools': []},
        headers: {'authorization': 'Bearer synthetic-token'},
      );
      expect(empty.status, 200, reason: empty.text);
      expect(upstream.requests, hasLength(2));
      expect((upstream.requests.last.body! as Map)['tools'], isEmpty);
    },
  );
}
