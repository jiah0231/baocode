import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/proxy/model_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final protocol in ProviderProtocol.values.where(
    (p) =>
        p == ProviderProtocol.anthropic ||
        p == ProviderProtocol.openaiChat ||
        p == ProviderProtocol.openaiResponses,
  )) {
    test(
      '$protocol forwards fragmented UTF-8 text before upstream closes',
      () async {
        final previousOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = previousOverrides);
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final finish = Completer<void>();
        final firstText = Completer<String>();
        final provider = ModelProvider(
          id: 'p',
          name: 'P',
          protocol: protocol,
          baseUrl: 'http://127.0.0.1:${upstream.port}/v1',
          models: const [ProviderModel(id: 'm')],
        );
        final proxy = ModelProxy(
          provider: (_) => provider,
          key: (_) async => 'key',
          findProxy: (_) => 'DIRECT',
          token: 'test-token',
        );
        final client = HttpClient();
        Future<void>? handler;
        final serverSubscription = upstream.listen((request) {
          handler = () async {
            await request.drain<void>();
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            final events = switch (protocol) {
              ProviderProtocol.openaiChat => [
                {
                  'id': 'c',
                  'model': 'm',
                  'choices': [
                    {
                      'index': 0,
                      'delta': {'role': 'assistant', 'content': '你好'},
                      'finish_reason': null,
                    },
                  ],
                },
              ],
              ProviderProtocol.openaiResponses => [
                {
                  'type': 'response.created',
                  'response': {'id': 'r', 'model': 'm'},
                },
                {
                  'type': 'response.output_item.added',
                  'output_index': 0,
                  'item': {
                    'type': 'message',
                    'id': 'msg',
                    'role': 'assistant',
                    'content': [],
                  },
                },
                {
                  'type': 'response.output_text.delta',
                  'output_index': 0,
                  'content_index': 0,
                  'delta': '你好',
                },
              ],
              _ => [
                {
                  'type': 'content_block_delta',
                  'index': 0,
                  'delta': {'type': 'text_delta', 'text': '你好'},
                },
              ],
            };
            // Comments, blanks, and malformed JSON must not become text.
            if (protocol != ProviderProtocol.anthropic) {
              request.response.write(
                ': keepalive\r\n\r\ndata: not-json\r\n\r\n',
              );
              await request.response.flush();
            }
            // Split inside both SSE fields and multi-byte characters.
            for (final event in events) {
              for (final byte in utf8.encode(
                'data: ${jsonEncode(event)}\r\n\r\n',
              )) {
                request.response.add([byte]);
                await request.response.flush();
              }
            }
            await finish.future;
            await request.response.close();
          }();
        });
        Future<void>? reading;
        try {
          final endpoint = await proxy.endpoint('p');
          final request = await client.postUrl(
            Uri.parse('${endpoint.baseUrl}/v1/messages'),
          );
          request.headers.set('authorization', 'Bearer test-token');
          request.headers.contentType = ContentType.json;
          request.write(
            jsonEncode({
              'model': 'm',
              'max_tokens': 128,
              'stream': true,
              'messages': [
                {'role': 'user', 'content': 'hello'},
              ],
            }),
          );
          final response = await request.close();
          reading = response
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .forEach((line) {
                if (!line.startsWith('data: ')) return;
                final data = jsonDecode(line.substring(6));
                if (data case {
                  'delta': {'type': 'text_delta', 'text': final String text},
                }) {
                  if (!firstText.isCompleted) firstText.complete(text);
                }
              });
          expect(
            await firstText.future.timeout(const Duration(seconds: 5)),
            '你好',
          );
          expect(finish.isCompleted, isFalse);
          finish.complete();
          await reading;
          await handler;
        } finally {
          if (!finish.isCompleted) finish.complete();
          // Release and drain the producer/consumer before closing sockets,
          // including failed first-text assertions.
          try {
            await handler;
            await reading;
          } finally {
            client.close(force: true);
            await proxy.close();
            await serverSubscription.cancel();
            await upstream.close(force: true);
          }
        }
      },
    );
  }
}
