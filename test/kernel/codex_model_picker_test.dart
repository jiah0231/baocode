import 'dart:async';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/models/upstream.dart';
import 'package:flutter_test/flutter_test.dart';

const _managed = '@magpie/codex/gpt-6.1-sol';
const _native = 'gpt-6.1-sol';

class _Server implements CodexTransport {
  final output = StreamController<Map<String, Object?>>.broadcast();
  final stopped = Completer<void>();
  final written = <Map<String, Object?>>[];
  String savedModel = _native;
  String savedProvider = 'openai';
  bool listNativeModels = true;

  @override
  Stream<Map<String, Object?>> get messages => output.stream;

  @override
  Future<void> get exited => stopped.future;

  @override
  void close() {
    if (!output.isClosed) unawaited(output.close());
    if (!stopped.isCompleted) stopped.complete();
  }

  Map request(String method) =>
      written.firstWhere((message) => message['method'] == method)['params']
          as Map;

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    if (message['id'] == null || message['method'] == null) return;
    final params = message['params'] as Map? ?? const {};
    final result = switch (message['method']) {
      'initialize' => {'userAgent': 'codex/0.166.0 (fixture)'},
      'model/list' when !listNativeModels => <String, Object?>{},
      'model/list' => {
        'data': [
          {
            'id': _native,
            'displayName': 'GPT-6.1-Sol',
            'supportedReasoningEfforts': [
              {'reasoningEffort': 'low'},
              {'reasoningEffort': 'ultra'},
            ],
            'defaultReasoningEffort': 'low',
            'serviceTiers': [
              {'id': 'priority', 'name': 'Priority'},
            ],
          },
        ],
      },
      'thread/read' || 'thread/resume' => {
        'thread': {
          'id': params['threadId'],
          'model': savedModel,
          'modelProvider': savedProvider,
          'turns': <Object?>[],
        },
      },
      'thread/start' => {
        'thread': {
          'id': 'new-thread',
          'model': params['model'],
          'modelProvider': params['modelProvider'] ?? 'openai',
        },
      },
      'thread/fork' => {
        'thread': {
          'id': 'native-copy',
          'model': _native,
          'modelProvider': 'openai',
        },
      },
      'turn/start' => {
        'turn': {'id': 'turn-1'},
      },
      _ => <String, Object?>{},
    };
    scheduleMicrotask(() {
      if (!output.isClosed) output.add({'id': message['id'], 'result': result});
    });
  }
}

void main() {
  late ModelProviders providers;
  late _Server server;
  late List<CodexLaunch> launches;
  late List<_Server> servers;

  setUp(() {
    CodexKernel.modelCache = null;
    final models = mergeModelList(
      const [ProviderModel(id: 'codex/gpt-6.1-sol')],
      parseModelList({
        'data': [
          {
            'id': 'codex/gpt-6.1-sol',
            'supported_reasoning_levels': [
              {'effort': 'low'},
              {'effort': 'ultra'},
            ],
          },
        ],
      }),
    );
    providers = ModelProviders.memory(
      providers: [
        ModelProvider(
          id: 'magpie',
          name: 'magpie',
          protocol: ProviderProtocol.openaiResponses,
          models: models,
        ),
      ],
    );
    server = _Server();
    launches = [];
    servers = [];
  });
  tearDown(() {
    providers.dispose();
    CodexKernel.modelCache = null;
  });

  CodexKernel kernel({KernelContext context = const KernelContext()}) {
    final value = CodexKernel(
      MockKernels.codex,
      context,
      providers: providers,
      start: (launch) async {
        launches.add(launch);
        final next = servers.isEmpty
            ? server
            : (_Server()
                ..savedModel = server.savedModel
                ..savedProvider = server.savedProvider);
        servers.add(next);
        return next;
      },
      providerProxy: () async =>
          (baseUrl: 'http://127.0.0.1:9/p/codex', token: 'fixture-only'),
    );
    addTearDown(value.dispose);
    return value;
  }

  test(
    'managed chats omit the native group before and after discovery',
    () async {
      final value = kernel();
      expect(value.model.selected, _managed);
      expect(value.model.options.map((o) => o.id), [_managed]);
      value.prepare();
      await pumpEventQueue(times: 40);
      expect(value.model.options.map((o) => o.group?.label), ['magpie']);
      expect(value.model.selected, _managed);
      expect(launches.single.modelProvider, 'baocode');
    },
  );

  test(
    'enabling the first provider aligns the displayed and runtime model',
    () async {
      final provider = providers.providers.single;
      await providers.save(provider.copyWith(enabled: false));
      final value = kernel();
      await providers.save(provider);
      server.listNativeModels = false;
      expect(value.model.selected, _managed);
      expect(value.model.options.map((o) => o.id), [_managed]);
      value.send(const KernelTurn(id: 'one', text: 'fixture'));
      await pumpEventQueue(times: 40);
      expect(launches.single.modelProvider, 'baocode');
      expect(server.request('turn/start')['model'], '$_managed(low)');
    },
  );

  test('a new chat no longer inherits a separate native model selection', () {
    final value = kernel(
      context: const KernelContext(settings: {'model': _native}),
    );
    expect(value.model.selected, _managed);
    expect(value.model.options.map((o) => o.id), [_managed]);
  });

  test(
    'advertised Ultra is selectable and sent without changing its value',
    () async {
      final value = kernel();
      expect(value.effort.optionsFor(_managed).map((o) => o.id), [
        'low',
        'ultra',
      ]);
      expect(value.effort.optionsFor(_managed).last.label, 'Ultra');
      value.effort.select(_managed, 'ultra');
      value.send(const KernelTurn(id: 'one', text: 'fixture'));
      await pumpEventQueue(times: 40);
      expect(launches.single.model, '$_managed(ultra)');
      expect(launches.single.effort, 'ultra');
      expect(server.request('turn/start')['model'], '$_managed(ultra)');
      expect(server.request('turn/start')['effort'], 'ultra');
      expect(value.effort.selected, 'ultra');
    },
  );

  test('a provider without advertised Ultra does not gain it', () async {
    final provider = providers.providers.single;
    await providers.save(
      provider.copyWith(
        models: const [
          ProviderModel(id: 'codex/gpt-6.1-sol', efforts: ['low']),
        ],
      ),
    );
    final value = kernel();
    value.prepare();
    await pumpEventQueue(times: 40);
    // The native catalog's Ultra is not evidence for a different provider.
    expect(value.effort.optionsFor(_managed).map((o) => o.id), ['low']);
  });

  test(
    'without enabled managed chat models the native fallback remains',
    () async {
      final provider = providers.providers.single;
      await providers.save(provider.copyWith(enabled: false));
      final value = kernel();
      expect(value.model.options.single.group?.label, 'Codex');
      value.prepare();
      await pumpEventQueue(times: 40);
      expect(value.model.selected, _native);
      expect(value.model.options.single.id, _native);
      expect(launches.single.proxy, isNull);
    },
  );

  KernelContext savedNative() => KernelContext(
    settings: const {'model': _native},
    resume: SessionRecord(
      id: 'old-native',
      title: 'Saved',
      updatedAt: DateTime(2026),
      cwd: '',
    ),
  );

  test(
    'copying native history never converts its helper to a managed route',
    () async {
      final value = kernel(context: savedNative());
      final copied = await value.fork(title: 'Copy');
      expect(copied?.id, 'native-copy');
      expect(value.sessionId, 'old-native');
      expect(launches, hasLength(2));
      expect(launches.every((launch) => launch.proxy == null), true);
      expect(servers.last.request('thread/fork')['modelProvider'], 'openai');
      expect(servers.last.request('thread/fork').containsKey('config'), false);
      expect(servers.last.stopped.isCompleted, true);
      expect(servers.first.stopped.isCompleted, false);
    },
  );

  test(
    'managed choice made before cold native resume restores a unified picker',
    () async {
      final value = kernel(context: savedNative());
      value.model.select(_managed);
      expect(await value.prepareConversation(), true);
      expect(value.sessionId, 'old-native');
      expect(launches, hasLength(2));
      expect(launches.first.proxy, isNotNull);
      expect(launches.last.proxy, isNull);
      expect(value.model.selected, _managed);
      expect(value.model.options.map((o) => o.id), [_managed]);
      expect(
        servers
            .expand((s) => s.written)
            .any((m) => m['method'] == 'thread/fork'),
        false,
      );
    },
  );

  test(
    'native choice made before cold managed resume stays in the picker',
    () async {
      server
        ..savedModel = _managed
        ..savedProvider = 'baocode';
      final value = kernel(
        context: KernelContext(
          settings: const {'model': _managed, 'fast@$_native': 'fast'},
          resume: savedNative().resume,
        ),
      );
      value.model.select(_native);
      expect(await value.prepareConversation(), true);
      expect(value.sessionId, 'old-native');
      expect(value.model.selected, _native);
      expect(value.model.options.any((option) => option.id == _native), true);
      expect(value.fast.selected, 'fast');
      expect(
        servers
            .expand((s) => s.written)
            .any((m) => m['method'] == 'thread/fork'),
        false,
      );
    },
  );

  for (final hasSavedModel in [false, true]) {
    test(
      'saved native chats retain their route (saved model=$hasSavedModel)',
      () async {
        final value = kernel(
          context: KernelContext(
            settings: {if (hasSavedModel) 'model': _native},
            resume: SessionRecord(
              id: 'old-native',
              title: 'Saved',
              updatedAt: DateTime(2026),
              cwd: '',
            ),
          ),
        );
        expect(await value.prepareConversation(), true);
        expect(launches.single.proxy, isNull);
        expect(value.model.selected, _native);
        expect(value.sessionId, 'old-native');
        expect(value.model.options.any((o) => o.id == _native), true);
        expect(server.written.any((m) => m['method'] == 'thread/fork'), false);
        // Switching is still an explicit action, not a side effect of listing.
        expect(value.switchRestarts(_managed), true);
        value.model.select(_managed);
        expect(value.model.options.map((o) => o.id), [_managed]);
      },
    );
  }
}
