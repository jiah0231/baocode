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
        firstText.future.ignore();
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
            await request.drain<void>().timeout(const Duration(seconds: 10));
            request.response.bufferOutput = false;
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
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
            // Split the SSE field and the first multi-byte character, but
            // avoid hundreds of tiny TCP writes unrelated to framing coverage.
            for (final event in events) {
              final bytes = utf8.encode('data: ${jsonEncode(event)}\r\n\r\n');
              final multibyte = bytes.indexWhere((byte) => byte >= 0x80);
              final cuts = <int>{
                0,
                3,
                if (multibyte >= 0) multibyte + 1,
                bytes.length - 1,
                bytes.length,
              }.toList()..sort();
              for (var i = 1; i < cuts.length; i++) {
                request.response.add(bytes.sublist(cuts[i - 1], cuts[i]));
                await request.response.flush().timeout(
                  const Duration(seconds: 10),
                );
              }
            }
            await finish.future.timeout(const Duration(seconds: 20));
            await request.response.close().timeout(const Duration(seconds: 10));
          }();
          // Observe failures immediately rather than leaving the consumer
          // awaiting headers until the entire test times out.
          unawaited(
            handler!.then<void>(
              (_) {},
              onError: (Object error, StackTrace stack) {
                if (!firstText.isCompleted) {
                  firstText.completeError(error, stack);
                }
              },
            ),
          );
        });
        StreamSubscription<String>? reading;
        final readDone = Completer<void>();
        readDone.future.ignore();
        try {
          final endpoint = await proxy
              .endpoint('p')
              .timeout(const Duration(seconds: 10));
          final request = await client
              .postUrl(Uri.parse('${endpoint.baseUrl}/v1/messages'))
              .timeout(const Duration(seconds: 10));
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
          final response = await request.close().timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'Waiting for proxy response headers: $protocol',
            ),
          );
          reading = response
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (line) {
                  if (!line.startsWith('data: ')) return;
                  final data = jsonDecode(line.substring(6));
                  if (data case {
                    'delta': {'type': 'text_delta', 'text': final String text},
                  }) {
                    if (!firstText.isCompleted) firstText.complete(text);
                  }
                },
                onDone: () {
                  if (!readDone.isCompleted) readDone.complete();
                },
                onError: (Object error, StackTrace stack) {
                  if (!firstText.isCompleted) {
                    firstText.completeError(error, stack);
                  }
                  if (!readDone.isCompleted) {
                    readDone.completeError(error, stack);
                  }
                },
              );
          expect(
            await firstText.future.timeout(
              const Duration(seconds: 5),
              onTimeout: () => throw TimeoutException(
                'Waiting for first translated text: $protocol',
              ),
            ),
            '你好',
          );
          expect(finish.isCompleted, isFalse);
          finish.complete();
          await readDone.future.timeout(const Duration(seconds: 10));
          await handler?.timeout(const Duration(seconds: 10));
        } finally {
          if (!finish.isCompleted) finish.complete();
          // Close peers first on failure so a producer's blocked flush or
          // consumer's read cannot prevent teardown. Every drain is bounded.
          client.close(force: true);
          await reading?.cancel().timeout(const Duration(seconds: 5));
          await upstream.close(force: true).timeout(const Duration(seconds: 5));
          await serverSubscription.cancel().timeout(const Duration(seconds: 5));
          try {
            await handler?.timeout(const Duration(seconds: 5));
          } on Object {
            // A failed phase already reports the error above; peer closure
            // may additionally interrupt an outstanding write.
          }
          await proxy.close().timeout(const Duration(seconds: 5));
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}
