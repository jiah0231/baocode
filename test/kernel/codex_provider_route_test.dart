import 'dart:async';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_proxy_configuration.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter_test/flutter_test.dart';

const _selected = '@fixture/model';
const _dummy = 'fixture-process-only';

class _Runtime {
  final servers = <_Server>[];
  final threads = <String, Map<String, Object?>>{};
  int serial = 0;
  Completer<void>? resumeGate;

  Future<CodexTransport> start(CodexLaunch launch) async {
    final server = _Server(this, launch);
    servers.add(server);
    return server;
  }
}

class _Server implements CodexTransport {
  _Server(this.runtime, this.launch);
  final _Runtime runtime;
  final CodexLaunch launch;
  final output = StreamController<Map<String, Object?>>.broadcast();
  final stopped = Completer<void>();
  final written = <Map<String, Object?>>[];
  String get provider => launch.proxy == null ? 'openai' : 'baocode';
  int turns = 0;
  @override
  Stream<Map<String, Object?>> get messages => output.stream;
  @override
  Future<void> get exited => stopped.future;
  @override
  void close() {
    if (!output.isClosed) unawaited(output.close());
    if (!stopped.isCompleted) stopped.complete();
  }

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final method = message['method'];
    if (method == null || message['id'] == null) return;
    final params = message['params'] as Map? ?? const {};
    Map<String, Object?> result = {};
    String? error;
    switch (method) {
      case 'initialize':
        result = {'userAgent': 'baocode/0.166.0 (fixture)'};
      case 'thread/start':
      case 'thread/fork':
        final id = 'thread-${++runtime.serial}';
        final thread = <String, Object?>{
          'id': id,
          'modelProvider': params['modelProvider'] ?? provider,
          'model': params['model'] ?? 'native-model',
          'turns': <Object?>[],
        };
        runtime.threads[id] = thread;
        result = {'thread': thread};
      case 'thread/read':
        result = {'thread': runtime.threads[params['threadId']]};
      case 'thread/resume':
      case 'turn/start':
        final thread = runtime.threads[params['threadId']];
        if (thread == null || thread['modelProvider'] != provider ||
            (params['modelProvider'] != null && params['modelProvider'] != provider)) {
          error = 'This chat uses ${thread?['modelProvider']}, but your current provider is $provider.';
        } else if (method == 'thread/resume') {
          result = {'thread': thread};
        } else {
          result = {'turn': {'id': 'turn-${++turns}'}};
        }
    }
    void reply() {
      if (output.isClosed) return;
      output.add({
        'id': message['id'],
        if (error != null) 'error': {'code': -32600, 'message': error}
        else 'result': result,
      });
    }
    final gate = method == 'thread/resume' ? runtime.resumeGate : null;
    if (gate != null) {
      unawaited(gate.future.then((_) => reply()));
    } else {
      scheduleMicrotask(reply);
    }
  }

  void complete() => output.add({
    'method': 'turn/completed',
    'params': {'turn': {'id': 'turn-$turns', 'status': 'completed'}},
  });
}

void main() {
  late _Runtime runtime;
  late ModelProviders providers;
  late CodexKernel kernel;
  setUp(() {
    runtime = _Runtime();
    providers = ModelProviders.memory(providers: [
      ModelProvider.fromJson({
        'id': 'fixture', 'name': 'Fixture', 'protocol': 'openai-responses',
        'baseUrl': 'https://example.invalid/v1',
        'models': [{'id': 'model', 'contextWindow': 128000}],
      })!,
    ]);
    kernel = CodexKernel(MockKernels.codex, const KernelContext(cwd: '/fixture'),
      start: runtime.start, providers: providers,
      providerProxy: () async => (baseUrl: 'http://127.0.0.1:9/p/codex', token: _dummy),
    );
  });
  tearDown(() {
    kernel.dispose();
    providers.dispose();
  });

  Future<void> send(String id) async {
    kernel.send(KernelTurn(id: id, text: 'fixture'));
    await pumpEventQueue(times: 50);
  }

  test('proxy provider and definition are process scoped; token stays out of args', () async {
    kernel.model.select(_selected);
    await send('first');
    final server = runtime.servers.single;
    expect(server.turns, 1);
    expect(server.launch.modelProvider, 'baocode');
    expect(server.launch.arguments.join(' '), contains("model_provider='baocode'"));
    expect(server.launch.arguments.join(' '), isNot(contains(_dummy)));
    expect(server.launch.proxy!.environment[CodexProxyConfiguration.tokenVariable] == _dummy, true);
    expect(server.launch.proxy!.provider['env_key'], CodexProxyConfiguration.tokenVariable);
    expect(server.launch.proxy!.provider.containsKey('experimental_bearer_token'), false);
  });

  for (final fromProxy in [false, true]) {
    test('prepare then change model before first send (fromProxy=$fromProxy)', () async {
      kernel.model.select(fromProxy ? _selected : 'default');
      kernel.prepare();
      await pumpEventQueue(times: 30);
      kernel.model.select(fromProxy ? 'default' : _selected);
      await send('first');
      expect(runtime.servers, hasLength(2));
      expect(runtime.servers.first.stopped.isCompleted, true);
      expect(runtime.servers.last.provider, fromProxy ? 'openai' : 'baocode');
      expect(runtime.servers.last.turns, 1);
      expect(runtime.servers.expand((s) => s.written).where((m) => m['method'] == 'thread/fork'), isEmpty);
    });

    test('explicit cross-provider switch uses target helper (fromProxy=$fromProxy)', () async {
      kernel.model.select(fromProxy ? _selected : 'default');
      await send('first');
      final source = kernel.sessionId!;
      final sourceProvider = runtime.threads[source]!['modelProvider'];
      runtime.servers.single.complete();
      await pumpEventQueue();
      final target = fromProxy ? 'default' : _selected;
      expect(kernel.switchRestarts(target), true);
      kernel.model.select(target);
      await send('second');
      expect(runtime.servers, hasLength(3));
      expect(runtime.servers[1].provider, fromProxy ? 'openai' : 'baocode');
      expect(runtime.servers[1].stopped.isCompleted, true);
      expect(runtime.servers.last.turns, 1);
      expect(kernel.sessionId, isNot(source));
      expect(runtime.threads[source]!['modelProvider'], sourceProvider);
      expect(runtime.servers.first.written.where((m) => m['method'] == 'thread/fork'), isEmpty);
      expect(runtime.servers[1].written.where((m) => m['method'] == 'thread/fork'), hasLength(1));
    });
  }

  for (final fromProxy in [false, true]) {
    test('released history honors explicit provider switch (fromProxy=$fromProxy)', () async {
      kernel.model.select(fromProxy ? _selected : 'default');
      await send('first');
      final source = kernel.sessionId!;
      final sourceProvider = runtime.threads[source]!['modelProvider'];
      runtime.servers.single.complete();
      await pumpEventQueue();
      kernel.release();
      kernel.model.select(fromProxy ? 'default' : _selected);
      await send('second');
      expect(runtime.servers.last.turns, 1);
      expect(kernel.sessionId, isNot(source));
      expect(runtime.threads[source]!['modelProvider'], sourceProvider);
      expect(runtime.servers.expand((s) => s.written).where((m) => m['method'] == 'thread/fork'), hasLength(1));
    });
  }

  test('ordinary copy preserves the source proxy route and leaves source active', () async {
    kernel.model.select(_selected);
    await send('first');
    runtime.servers.single.complete();
    await pumpEventQueue();
    final source = kernel.sessionId;
    final copied = await kernel.fork(title: 'Copy');
    expect(copied, isNotNull);
    expect(kernel.sessionId, source);
    expect(runtime.threads[copied!.id]!['modelProvider'], 'baocode');
    expect(runtime.servers.last.provider, 'baocode');
    expect(runtime.servers.first.stopped.isCompleted, false);
    expect(runtime.servers.last.stopped.isCompleted, true);
  });

  test('proxy history resumes and restarts on its original ID without a fork', () async {
    kernel.dispose();
    runtime.threads['saved'] = {'id': 'saved', 'modelProvider': 'baocode', 'model': _selected, 'turns': <Object?>[]};
    kernel = CodexKernel(MockKernels.codex, KernelContext(
      cwd: '/fixture', settings: const {'model': _selected},
      resume: SessionRecord(id: 'saved', title: 'Saved', updatedAt: DateTime(2026), cwd: '/fixture'),
    ), start: runtime.start, providers: providers,
      providerProxy: () async => (baseUrl: 'http://127.0.0.1:9/p/codex', token: _dummy),
    );
    expect(await kernel.prepareConversation(), true);
    expect(kernel.sessionId, 'saved');
    kernel.restart();
    await pumpEventQueue(times: 40);
    await send('continued');
    expect(kernel.sessionId, 'saved');
    expect(runtime.servers.last.turns, 1);
    expect(runtime.servers.every((s) => s.provider == 'baocode'), true);
    expect(runtime.servers.expand((s) => s.written).where((m) => m['method'] == 'thread/fork'), isEmpty);
  });

  test('cold history recovers its saved proxy model without local model settings', () async {
    kernel.dispose();
    runtime.threads['saved'] = {'id': 'saved', 'modelProvider': 'baocode', 'model': _selected, 'turns': <Object?>[]};
    kernel = CodexKernel(MockKernels.codex, KernelContext(cwd: '/fixture',
      resume: SessionRecord(id: 'saved', title: 'Saved', updatedAt: DateTime(2026), cwd: '/fixture'),
    ), start: runtime.start, providers: providers,
      providerProxy: () async => (baseUrl: 'http://127.0.0.1:9/p/codex', token: _dummy),
    );
    expect(await kernel.prepareConversation(), true);
    expect(kernel.sessionId, 'saved');
    expect(runtime.servers.last.provider, 'baocode');
    expect(runtime.servers.expand((s) => s.written).where((m) => m['method'] == 'thread/fork'), isEmpty);
  });

  test('a newer model choice replaces the pending choice during cold resume', () async {
    kernel.dispose();
    runtime.threads['saved'] = {'id': 'saved', 'modelProvider': 'openai', 'model': 'native-model', 'turns': <Object?>[]};
    kernel = CodexKernel(MockKernels.codex, KernelContext(cwd: '/fixture',
      resume: SessionRecord(id: 'saved', title: 'Saved', updatedAt: DateTime(2026), cwd: '/fixture'),
    ), start: runtime.start, providers: providers,
      providerProxy: () async => (baseUrl: 'http://127.0.0.1:9/p/codex', token: _dummy),
    );
    kernel.model.select(_selected);
    final gate = runtime.resumeGate = Completer<void>();
    final prepared = kernel.prepareConversation();
    await pumpEventQueue(times: 50);
    expect(runtime.servers.last.provider, 'openai');
    expect(runtime.servers.last.written.where((m) => m['method'] == 'thread/resume'), hasLength(1));
    kernel.model.select('default');
    gate.complete();
    expect(await prepared, true);
    expect(kernel.model.selected, 'default');
    await send('latest');
    expect(kernel.sessionId, 'saved');
    expect(runtime.servers.last.turns, 1);
    expect(runtime.servers.expand((s) => s.written).where((m) => m['method'] == 'thread/fork'), isEmpty);
  });

  test('a native provider rejection never forks as an error workaround', () async {
    kernel.dispose();
    runtime.threads['saved'] = {'id': 'saved', 'modelProvider': 'other', 'model': 'native-model'};
    kernel = CodexKernel(MockKernels.codex, KernelContext(cwd: '/fixture',
      resume: SessionRecord(id: 'saved', title: 'Saved', updatedAt: DateTime(2026), cwd: '/fixture'),
    ), start: runtime.start, providers: providers);
    expect(await kernel.prepareConversation(), false);
    expect(runtime.threads.keys, ['saved']);
    expect(runtime.servers.expand((s) => s.written).where((m) => m['method'] == 'thread/fork'), isEmpty);
  });
}
