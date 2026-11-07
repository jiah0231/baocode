import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/testing.dart';
import 'package:bao_agent/bao_agent.dart' show EngineOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/claude_code/claude_haiku.dart';
import 'package:baocode/quick_ask/quick_ask_service.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/models/model_runtime.dart';
import 'package:baocode/network/network_proxy_io.dart';
import 'package:baocode/network/proxy_settings.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('auxiliary title opt-out survives engine isolate serialization', () {
    const ordinary = EngineOptions(cwd: '/tmp');
    expect(ordinary.autoTitle, isTrue);
    expect(EngineOptions.fromJson({'cwd': '/tmp'}).autoTitle, isTrue);
    const auxiliary = EngineOptions(cwd: '/tmp', autoTitle: false);
    expect(EngineOptions.fromJson(auxiliary.toJson()).autoTitle, isFalse);
  });

  test('a question alone goes on stdin, its answer one JSON result', () {
    final arguments = claudeHaikuArguments('Be brief.');
    expect(arguments, isNot(contains('--input-format')));
    expect(arguments.join(' '), contains('--output-format json'));
    // No tools.
    expect(
      arguments.sublist(
        arguments.indexOf('--tools'),
        2 + arguments.indexOf('--tools'),
      ),
      ['--tools', ''],
    );
  });

  test('with pictures, a stream-json message: each after a line naming '
      'it, the question last; still no tools', () {
    final arguments = claudeHaikuArguments('Be brief.', message: true);
    expect(
      arguments.join(' '),
      contains('--input-format stream-json --output-format stream-json'),
    );
    expect(arguments, contains('--verbose'));
    expect(arguments, contains('--tools'));

    final image = ImageAttachment(
      bytes: Uint8List.fromList([1, 2, 3]),
      mediaType: 'image/png',
    );
    final message = jsonDecode(
      claudeHaikuMessage('What is it?', [(name: '1/shot.png', image: image)]),
    ) as Map<String, Object?>;
    expect(message['type'], 'user');
    expect((message['message']! as Map)['content'], [
      {'type': 'text', 'text': '[Picture: 1/shot.png]'},
      {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': 'image/png',
          'data': base64Encode([1, 2, 3]),
        },
      },
      {'type': 'text', 'text': 'What is it?'},
    ]);
  });

  test('with tools, those alone, some turns, and the folders it may read', () {
    const tools = ClaudeHaikuTools(
      directory: '/work/app',
      readable: ['/Users/me/BaoCode/Stash'],
      maxTurns: 16,
    );
    final arguments = claudeHaikuArguments('Be brief.', tools: tools);
    expect(
      arguments.sublist(
        arguments.indexOf('--tools'),
        2 + arguments.indexOf('--tools'),
      ),
      ['--tools', 'Read'],
    );
    expect(arguments.join(' '), contains('--max-turns 16'));
    expect(tools.settings, {
      'permissions': {
        'allow': ['Read(//Users/me/BaoCode/Stash/**)'],
      },
    });
    expect(const ClaudeHaikuTools().settings, isEmpty);
  });

  test('the answer is read from verbose output\'s array of events, not '
      'taken from stderr', () {
    final output = jsonEncode([
      {'type': 'system', 'subtype': 'init'},
      {'type': 'assistant'},
      {'type': 'result', 'is_error': false, 'result': 'Tidied.'},
    ]);
    expect(
      claudeHaikuAnswer(output, '[claude-code:unrecognized_model] {}', 0),
      'Tidied.',
    );
    expect(
      () => claudeHaikuAnswer('[{"type":"system"}]', 'It broke.', 1),
      throwsA(
        isA<ClaudeHaikuException>().having(
          (e) => e.message,
          'message',
          'It broke.',
        ),
      ),
    );
  });

  group('on BaoCode\'s own core', () {
    late FakeApi api;
    late Directory root;
    HttpOverrides? previousHttpOverrides;
    final previous = ModelProviders.current;
    final previousCore = ClaudeCore.current;

    setUp(() async {
      previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = _LoopbackHttpOverrides();
      root = Directory.systemTemp.createTempSync('baocode-haiku-');
      api = await FakeApi.start(errands: (_) => Reply.text('Short answer'));
      // The machine's own setup: a key and a Haiku of its own.
      ClaudeEnvironment.use({
        'HOME': root.path,
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'ANTHROPIC_API_KEY': 'sk-user',
        'ANTHROPIC_BASE_URL': api.baseUrl,
        'ANTHROPIC_DEFAULT_HAIKU_MODEL': 'user-haiku',
        ClaudeEnvironment.dataPathVariable: p.join(root.path, 'config'),
      });
      NetworkProxy.instance.follow(
        ValueNotifier(0),
        (key) => key == ProxyMode.settingKey ? ProxyMode.off.value : null,
      );
      ClaudeCore.current = () => ClaudeCore.builtin;
    });

    tearDown(() async {
      ModelProviders.current = previous;
      ClaudeCore.current = previousCore;
      ClaudeEnvironment.use(null);
      try {
        await api.close();
        await root.delete(recursive: true);
      } finally {
        HttpOverrides.global = previousHttpOverrides;
      }
    });

    test('quick ask streams through the builtin engine and Chat proxy before completion', () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      final cancel = Completer<void>();
      final first = Completer<String>();
      final chunks = <String>[];
      final requests = <Map<String, dynamic>>[];
      final handlers = <Future<void>>[];
      final subscription = upstream.listen((request) {
        handlers.add(() async {
          requests.add(
            jsonDecode(await utf8.decodeStream(request))
                as Map<String, dynamic>,
          );
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.bufferOutput = false;
          Future<void> chunk(String text, {bool end = false}) async {
            request.response.write(
              'data: ${jsonEncode({
                'id': 'quick-stream',
                'object': 'chat.completion.chunk',
                'model': 'quick-exact',
                'choices': [
                  {
                    'index': 0,
                    'delta': {'content': text},
                    'finish_reason': end ? 'stop' : null,
                  },
                ],
              })}\n\n',
            );
            await request.response.flush().timeout(const Duration(seconds: 10));
          }

          try {
            await chunk('你');
            // The test releases this only after QuickAskService.onText runs.
            await release.future.timeout(const Duration(seconds: 25));
            await chunk('好');
            await chunk('', end: true);
            request.response.write('data: [DONE]\n\n');
            await request.response.close();
          } on SocketException {
            // Cancellation after a failed assertion closes the peer.
          } on HttpException {
            // Same cleanup path on Windows HTTP sockets.
          }
        }());
      });
      final providers = ModelProviders.memory(
        providers: [
          ModelProvider(
            id: 'stream',
            name: 'Streaming',
            protocol: ProviderProtocol.openaiChat,
            baseUrl: 'http://127.0.0.1:${upstream.port}/v1',
            auth: ProviderAuth.apiKey,
            models: const [ProviderModel(id: 'quick-exact')],
          ),
        ],
      );
      ModelProviders.current = providers;
      await providers.setKey('stream', 'mock-key');
      await providers.setQuickAskModel('@stream/quick-exact');
      final answer = QuickAskService().ask(
        question: 'Translate hello',
        selectedText: 'hello',
        cancel: cancel.future,
        onText: (text) {
          chunks.add(text);
          if (!first.isCompleted) first.complete(text);
        },
      );
      final settled = answer.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      try {
        expect(await first.future.timeout(const Duration(seconds: 20)), '你');
        expect(release.isCompleted, isFalse);
        release.complete();
        expect(await answer.timeout(const Duration(seconds: 20)), '你好');
        expect(chunks, ['你', '你好']);
        expect(requests, hasLength(1));
        expect(requests.single['model'], 'quick-exact');
        expect(requests.single['stream'], isTrue);
        expect(requests.single['tools'] ?? [], isEmpty);
      } finally {
        if (!release.isCompleted) release.complete();
        cancel.complete();
        await settled.timeout(const Duration(seconds: 5));
        await stopModelProxy().timeout(const Duration(seconds: 5));
        await upstream.close(force: true).timeout(const Duration(seconds: 5));
        await subscription.cancel().timeout(const Duration(seconds: 5));
        await Future.wait(handlers).timeout(const Duration(seconds: 5));
        providers.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('no upstream: not asked of the machine\'s own setup', () async {
      ModelProviders.current = ModelProviders.memory();
      await expectLater(
        askClaudeHaiku('Be brief.', 'hi'),
        throwsA(
          isA<ClaudeHaikuException>().having(
            (error) => error.message,
            'message',
            ClaudeCore.noModel,
          ),
        ),
      );
      expect(api.headers, isEmpty);
    });

    test('no model of an upstream given: the first upstream\'s Haiku, '
        'with its key', () async {
      ModelProviders.current = ModelProviders.memory(
        providers: [
          ModelProvider(
            id: 'up',
            name: 'Upstream',
            baseUrl: api.baseUrl,
            auth: ProviderAuth.apiKey,
            models: const [
              ProviderModel(id: 'big'),
              ProviderModel(id: 'small'),
            ],
            roles: const ProviderRoles(haiku: 'small'),
          ),
        ],
      );
      await ModelProviders.current.setKey('up', 'sk-up');
      expect(await askClaudeHaiku('Be brief.', 'hi'), 'Short answer');
      expect(api.model.requests.map((r) => r.body['model']).toSet(), {'small'});
      expect(api.headers.map((h) => h['x-api-key']).toSet(), {'sk-up'});
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}

/// These fixtures speak real HTTP only to their in-process FakeApi/proxy.
/// The widget test binding's blanket 400 client is inappropriate here, but
/// removing it must not accidentally allow a test to call a real model API.
class _LoopbackHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      final address = uri.host == 'localhost'
          ? InternetAddress.loopbackIPv4
          : InternetAddress.tryParse(uri.host);
      if (proxyHost != null || address == null || !address.isLoopback) {
        throw StateError('Fixture HTTP must stay on loopback: $uri');
      }
      return Socket.startConnect(address, uri.port);
    };
    return client;
  }
}
