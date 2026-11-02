import 'dart:async';
import 'dart:io';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter_test/flutter_test.dart';

// A matched synchronous stream event proves the condition, but its producer
// may still be dispatching. Resume actions on the next event-loop turn rather
// than reentering that producer from a Future/stream continuation. This is a
// dispatch boundary, not a timed readiness wait or a retry.
Future<void> _afterEventDispatch() => Future<void>(() {});

void main() {
  late _WriterHarness h;
  setUp(() => h = _WriterHarness());
  tearDown(() => h.dispose());

  test('the fake rejects a second transport while the first owns a writer', () async {
    final first = h.kernel('source');
    expect(await first.prepareConversation(), isTrue);
    final second = h.kernel('source');
    expect(await second.prepareConversation(), isFalse);
    expect(second.health.detail, contains('already has an active writer'));
    expect(h.conflicts, 1);
    expect(h.writers['source'], same(h.servers.first));
  });

  test('restart waits for process exit, not merely close being requested', () async {
    final kernel = h.kernel('source');
    expect(await kernel.prepareConversation(), isTrue);
    final old = h.servers.single..delayExit = true;
    kernel.restart();
    await pumpEventQueue();
    expect(old.closeRequested, isTrue);
    expect(h.servers, hasLength(1));
    expect(h.writers['source'], same(old));
    old.finishExit();
    await h.ready(kernel, servers: 2);
    expect(h.servers, hasLength(2));
    expect(kernel.health.status, KernelHealthStatus.ready);
    expect(h.writers['source'], same(h.servers.last));
    expect(h.conflicts, 0);
  });

  test('rapid release and prepare do not overlap the old writer', () async {
    final kernel = h.kernel('source');
    expect(await kernel.prepareConversation(), isTrue);
    final old = h.servers.single..delayExit = true;
    kernel.release();
    kernel.prepare();
    await pumpEventQueue();
    expect(old.closeRequested, isTrue);
    expect(h.servers, hasLength(1));
    old.finishExit();
    await h.ready(kernel, servers: 2);
    expect(kernel.health.status, KernelHealthStatus.ready);
    expect(h.servers, hasLength(2));
    expect(h.conflicts, 0);
  });

  test('repeated restart shares one handoff instead of opening duplicate writers', () async {
    final kernel = h.kernel('source');
    expect(await kernel.prepareConversation(), isTrue);
    final old = h.servers.single..delayExit = true;
    kernel.restart();
    kernel.restart();
    kernel.prepare();
    kernel.restart();
    await pumpEventQueue();
    expect(h.servers, hasLength(1));
    old.finishExit();
    await h.ready(kernel, servers: 2);
    expect(kernel.health.status, KernelHealthStatus.ready);
    expect(h.servers, hasLength(2));
    expect(h.conflicts, 0);
  });

  test('restart installs its handoff before advancing an active turn to the queue', () async {
    final kernel = h.kernel('source');
    expect(await kernel.prepareConversation(), isTrue);
    kernel.send(const KernelTurn(id: 'active', text: 'First message'));
    kernel.send(const KernelTurn(id: 'queued', text: 'Queued message'));
    await h.until(() => h.servers.single.requests('turn/start').isNotEmpty,
        'the active turn to be sent before restarting');
    await pumpEventQueue(); // Drain the fake RPC response, not initialization IO.
    final old = h.servers.single..delayExit = true;
    expect(old.requests('turn/start'), hasLength(1));
    kernel.restart();
    await pumpEventQueue();
    expect(h.servers, hasLength(1));
    old.finishExit();
    await h.ready(kernel, servers: 2);
    expect(h.servers, hasLength(2));
    final replacement = h.servers.last;
    await h.until(() => replacement.requests('turn/start').isNotEmpty,
        'the queued turn to be sent');
    expect(kernel.health.status, KernelHealthStatus.ready);
    expect(replacement.requests('thread/resume'), hasLength(1));
    final queued = replacement.requests('turn/start').single['params'] as Map;
    expect(queued['input'], contains(equals({'type': 'text', 'text': 'Queued message'})));
    expect(h.servers.expand((s) => s.requests('turn/start')), hasLength(2));
    expect(h.conflicts, 0);
  });

  test('a cancelled proxy lookup cannot start a stale thread on the replacement', () async {
    final kernel = h.kernel('unused', resume: false);
    kernel.model.select('@custom/test-model');
    expect(await kernel.prepareConversation(), isTrue);
    final gate = Completer<void>();
    h.nextProxyGate = gate;
    kernel.send(const KernelTurn(id: 'stale', text: 'Cancelled message'));
    await h.until(() => h.proxyCalls == 1, 'the proxy lookup gate');
    final old = h.servers.single;
    expect(h.proxyCalls, 1);
    expect(old.requests('thread/start'), isEmpty);
    kernel.restart();
    await h.ready(kernel, servers: 2);
    expect(h.servers, hasLength(2));
    expect(kernel.health.status, KernelHealthStatus.ready);
    // The new lifecycle must not wait on the obsolete proxy lookup.
    kernel.send(const KernelTurn(id: 'fresh', text: 'Replacement message'));
    await h.until(() => h.servers.last.requests('turn/start').isNotEmpty,
        'the replacement turn to be sent');
    final replacement = h.servers.last;
    expect(replacement.requests('thread/start'), hasLength(1));
    final id = kernel.sessionId;
    expect(id, isNotNull);
    gate.complete();
    await pumpEventQueue();
    expect(kernel.sessionId, id);
    expect(old.requests('thread/start'), isEmpty);
    expect(replacement.requests('thread/start'), hasLength(1));
    expect(replacement.requests('turn/start'), hasLength(1));
    expect((replacement.requests('turn/start').single['params'] as Map)['threadId'], id);
    expect(h.writers.keys, [id]);
    expect(h.conflicts, 0);
  });

  test('dispose during a proxy lookup never creates a thread when the lookup finishes', () async {
    final kernel = h.kernel('unused', resume: false);
    kernel.model.select('@custom/test-model');
    expect(await kernel.prepareConversation(), isTrue);
    final gate = Completer<void>();
    h.nextProxyGate = gate;
    kernel.send(const KernelTurn(id: 'stale', text: 'Cancelled message'));
    await h.until(() => h.proxyCalls == 1, 'the proxy lookup gate');
    expect(h.proxyCalls, 1);
    kernel.dispose();
    gate.complete();
    await pumpEventQueue();
    expect(h.servers, hasLength(1));
    expect(h.servers.single.closeRequested, isTrue);
    expect(h.servers.single.requests('thread/start'), isEmpty);
    expect(kernel.sessionId, isNull);
    expect(h.writers, isEmpty);
  });

  test('restart during resume fences its stale proxy result before replacing the startup', () async {
    final kernel = h.kernel('source');
    kernel.model.select('@custom/test-model');
    final gate = Completer<void>();
    h.nextProxyGate = gate;
    kernel.prepare();
    await h.until(() => h.proxyCalls == 1, 'the proxy lookup gate');
    final old = h.servers.single;
    expect(h.proxyCalls, 1);
    expect(old.requests('thread/resume'), isEmpty);
    kernel.restart();
    await pumpEventQueue();
    // Resume is part of startup: join that startup until it observes its
    // cancellation, rather than opening a concurrent launch generation.
    expect(old.closeRequested, isTrue);
    expect(h.servers, hasLength(1));
    gate.complete();
    await h.ready(kernel, servers: 2);
    expect(h.servers, hasLength(2));
    expect(old.requests('thread/resume'), isEmpty);
    expect(h.servers.last.requests('thread/resume'), hasLength(1));
    expect(kernel.sessionId, 'source');
    expect(kernel.health.status, KernelHealthStatus.ready);
    expect(h.writers['source'], same(h.servers.last));
    expect(h.conflicts, 0);
  });

  test('disposing during a pending handoff does not launch a replacement', () async {
    final kernel = h.kernel('source');
    expect(await kernel.prepareConversation(), isTrue);
    final old = h.servers.single..delayExit = true;
    kernel.restart();
    await pumpEventQueue();
    kernel.dispose();
    old.finishExit();
    await pumpEventQueue();
    expect(h.servers, hasLength(1));
    expect(h.writers, isEmpty);
    expect(h.conflicts, 0);
  });

  testWidgets('a stuck process times out without stealing its writer, then retry recovers', (tester) async {
    final kernel = h.kernel('source');
    expect(await tester.runAsync(kernel.prepareConversation), isTrue);
    final old = h.servers.single..delayExit = true;
    kernel.restart();
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    expect(kernel.health.status, KernelHealthStatus.failed);
    expect(h.servers, hasLength(1));
    expect(h.writers['source'], same(old));
    old.finishExit();
    await tester.pump();
    expect(await tester.runAsync(kernel.prepareConversation), isTrue);
    expect(h.servers, hasLength(2));
    expect(h.conflicts, 0);
  });

  test('restart while launch is pending closes the stale launch before starting another', () async {
    final gate = Completer<void>();
    h.nextLaunchGate = gate;
    h.delayNewExits = true;
    final kernel = h.kernel('source');
    kernel.prepare();
    await h.until(() => h.servers.isNotEmpty, 'the initial launch gate');
    final stale = h.servers.single;
    kernel.restart();
    await pumpEventQueue();
    expect(h.servers, hasLength(1));
    gate.complete();
    await h.until(() => stale.closeRequested, 'the cancelled launch to close');
    expect(stale.closeRequested, isTrue);
    expect(stale.requests('thread/resume'), isEmpty);
    expect(h.servers, hasLength(1));
    stale.finishExit();
    await h.ready(kernel, servers: 2);
    expect(h.servers, hasLength(2));
    expect(kernel.health.status, KernelHealthStatus.ready);
    expect(h.conflicts, 0);
  });

  test('dispose while launch is pending closes the late transport without resuming', () async {
    final gate = Completer<void>();
    h.nextLaunchGate = gate;
    final kernel = h.kernel('source');
    kernel.prepare();
    await h.until(() => h.servers.isNotEmpty, 'the initial launch gate');
    final stale = h.servers.single;
    kernel.dispose();
    gate.complete();
    await h.until(() => stale.closeRequested, 'the cancelled launch to close');
    expect(stale.closeRequested, isTrue);
    expect(stale.requests('thread/resume'), isEmpty);
    expect(h.servers, hasLength(1));
    expect(h.writers, isEmpty);
  });

  test('fork releases its helper writer before exposing the copy and leaves the active source alone', () async {
    final source = h.kernel('source');
    expect(await source.prepareConversation(), isTrue);
    final owner = h.servers.single;
    source.send(const KernelTurn(id: 'active-input', text: 'Keep working'));
    await h.until(() => owner.requests('turn/start').isNotEmpty,
        'the active source turn to be sent');
    await pumpEventQueue(); // Its server turn ID is assigned by the fake reply.
    expect(owner.requests('turn/start'), hasLength(1));
    h.delayNewExits = true;
    var returned = false;
    final copied = source.fork(title: 'Copy').then((record) {
      returned = true;
      return record;
    });
    await h.until(
      () => h.servers.any((s) =>
          s.requests('thread/fork').isNotEmpty && s.closeRequested),
      'the fork helper to finish initialization, fork, name, and close',
    );
    final helper = h.servers.singleWhere(
      (s) => s.requests('thread/fork').isNotEmpty,
    );
    expect(helper, isNot(same(owner)));
    expect(helper.requests('thread/resume'), isEmpty);
    expect(helper.requests('thread/fork').single['params'], {
      'threadId': 'source',
      'beforeTurnId': 'server-turn-1',
      'deferGoalContinuation': true,
    });
    expect(helper.requests('thread/name/set'), hasLength(1));
    expect(helper.closeRequested, isTrue);
    expect(returned, isFalse);
    expect(h.writers['fork-1'], same(helper));
    expect(h.writers['source'], same(owner));
    expect(owner.closeRequested, isFalse);
    expect(owner.requests('turn/interrupt'), isEmpty);
    helper.finishExit();
    final record = await copied;
    expect(record?.id, 'fork-1');
    final child = h.kernel(record!.id);
    expect(await child.prepareConversation(), isTrue);
    expect(h.writers['source'], same(owner));
    expect(h.writers[record.id], isNot(same(helper)));
    expect(h.conflicts, 0);
  });

  test('cold fork never resumes the original and its copy can be opened immediately', () async {
    final source = h.kernel('source');
    final record = await source.fork(title: 'Cold copy');
    expect(record?.id, 'fork-1');
    expect(h.servers.expand((s) => s.requests('thread/resume')), isEmpty);
    expect(h.writers['source'], isNull);
    expect(h.writers['fork-1'], isNull);
    final child = h.kernel(record!.id);
    expect(await child.prepareConversation(), isTrue);
    expect(h.conflicts, 0);
  });

  test('provider switch hands off both original and copied writers before resuming the copy', () async {
    final kernel = h.kernel('source');
    expect(await kernel.prepareConversation(), isTrue);
    final old = h.servers.single;
    kernel.send(const KernelTurn(id: 'first', text: 'First turn'));
    await h.until(() => old.requests('turn/start').isNotEmpty,
        'the first provider turn to be sent');
    await pumpEventQueue(); // Drain the fake turn/start response.
    final firstEnded = kernel.events.firstWhere((event) => event is TurnEnded);
    old.notify('turn/completed', {
      'threadId': 'source',
      'turn': {'id': 'server-turn-1', 'status': 'completed'},
    });
    await firstEnded.timeout(const Duration(seconds: 10));
    await _afterEventDispatch();
    old.delayExit = true;
    kernel.model.select('@custom/test-model');
    kernel.send(const KernelTurn(id: 'second', text: 'Continue elsewhere'));
    await h.until(() => old.closeRequested, 'the provider fork writer handoff');
    expect(old.requests('thread/fork'), hasLength(1));
    expect((old.requests('thread/fork').single['params'] as Map)['modelProvider'], 'baocode');
    expect(old.closeRequested, isTrue);
    expect(h.servers, hasLength(1));
    expect(h.writers['source'], same(old));
    expect(h.writers['fork-1'], same(old));
    old.finishExit();
    await h.ready(kernel, servers: 2);
    expect(h.servers, hasLength(2));
    expect(kernel.sessionId, 'fork-1');
    expect(kernel.health.status, KernelHealthStatus.ready);
    final replacement = h.servers.last;
    await h.until(() => replacement.requests('turn/start').isNotEmpty,
        'the provider-switch turn to be sent');
    expect((replacement.requests('thread/resume').single['params'] as Map)['threadId'], 'fork-1');
    expect((replacement.requests('turn/start').single['params'] as Map)['threadId'], 'fork-1');
    expect(old.requests('turn/start'), hasLength(1));
    final original = h.kernel('source');
    expect(await original.prepareConversation(), isTrue);
    expect(h.writers['source'], isNot(same(replacement)));
    expect(h.conflicts, 0);
  });
}

/// A common writer registry models Codex's cross-process exclusion: a fork
/// acquires a child writer too, and close() alone does not release either lock.
class _WriterHarness {
  _WriterHarness() : home = Directory.systemTemp.createTempSync('codex-writers-');

  final Directory home;
  final providers = ModelProviders.memory(providers: [
    ModelProvider.fromJson({
      'id': 'custom',
      'name': 'Test provider',
      'protocol': 'openai-responses',
      'baseUrl': 'https://example.invalid/v1',
      'models': [
        {'id': 'test-model', 'label': 'Test model', 'contextWindow': 128000},
      ],
    })!,
  ]);
  final servers = <_WriterServer>[];
  final kernels = <CodexKernel>[];
  final writers = <String, _WriterServer>{};
  final threadProviders = <String, String>{};
  bool delayNewExits = false;
  Completer<void>? nextLaunchGate;
  Completer<void>? nextProxyGate;
  int proxyCalls = 0;
  int conflicts = 0;
  int forks = 0;
  int starts = 0;

  // Initialization performs real filesystem IO. Wait for observable state,
  // never a fixed number of event-loop pumps, and never call prepare/retry to
  // make a readiness assertion pass. Remaining pumps only drain fake RPC
  // microtasks or check that a deliberately blocked gate makes no progress.
  final _changes = StreamController<void>.broadcast(sync: true);
  final _kernelEvents = <StreamSubscription<KernelEvent>>[];

  void changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> until(bool Function() condition, String description) async {
    if (condition()) {
      await _afterEventDispatch();
      return;
    }
    final reached = Completer<void>();
    final subscription = _changes.stream.listen((_) {
      if (!reached.isCompleted && condition()) reached.complete();
    });
    try {
      await reached.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Waiting for $description'),
      );
    } finally {
      await subscription.cancel();
    }
    await _afterEventDispatch();
  }

  Future<void> ready(CodexKernel kernel, {required int servers}) async {
    await until(
      () => this.servers.length >= servers &&
          (kernel.health.status == KernelHealthStatus.ready ||
              kernel.health.status == KernelHealthStatus.failed),
      'generation $servers to report ready or failed',
    );
    expect(kernel.health.status, KernelHealthStatus.ready,
        reason: kernel.health.detail);
  }

  CodexKernel kernel(String id, {bool resume = true}) {
    final kernel = CodexKernel(
      MockKernels.codex,
      KernelContext(
        cwd: home.path,
        resume: resume
            ? SessionRecord(
                id: id,
                title: id,
                updatedAt: DateTime(2026),
                cwd: home.path,
              )
            : null,
      ),
      start: (_) async {
        final server = _WriterServer(this)..delayExit = delayNewExits;
        servers.add(server);
        changed();
        final gate = nextLaunchGate;
        nextLaunchGate = null;
        if (gate != null) await gate.future;
        return server;
      },
      providers: providers,
      providerProxy: () async {
        proxyCalls++;
        changed();
        final gate = nextProxyGate;
        nextProxyGate = null;
        if (gate != null) await gate.future;
        return (baseUrl: 'http://127.0.0.1:9/test/codex', token: 'test-token');
      },
    );
    kernels.add(kernel);
    _kernelEvents.add(kernel.events.listen((_) => changed()));
    return kernel;
  }

  Future<void> dispose() async {
    for (final kernel in kernels) {
      kernel.dispose();
    }
    for (final server in servers) {
      server.finishExit();
    }
    await pumpEventQueue();
    for (final subscription in _kernelEvents) {
      await subscription.cancel();
    }
    await _changes.close();
    await home.delete(recursive: true);
  }
}

class _WriterServer implements CodexTransport {
  _WriterServer(this.h);
  final _WriterHarness h;
  final _messages = StreamController<Map<String, Object?>>.broadcast();
  final _exited = Completer<void>();
  final written = <Map<String, Object?>>[];
  bool delayExit = false;
  bool closeRequested = false;
  int turns = 0;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  @override
  Future<void> get exited => _exited.future;

  Iterable<Map<String, Object?>> requests(String method) =>
      written.where((message) => message['method'] == method);

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    h.changed();
    if (message['id'] == null) return;
    final method = message['method'];
    final params = message['params'] as Map? ?? const {};
    String? thread;
    if (method == 'thread/start') thread = 'new-${++h.starts}';
    if (method == 'thread/resume') thread = params['threadId'] as String;
    if (method == 'thread/fork') thread = 'fork-${++h.forks}';
    if (thread != null) {
      final owner = h.writers[thread];
      if (owner != null && !identical(owner, this)) {
        h.conflicts++;
        _reply({
          'id': message['id'],
          'error': {
            'code': -32600,
            'message': 'thread $thread already has an active writer',
          },
        });
        return;
      }
      h.writers[thread] = this;
      h.threadProviders.putIfAbsent(
        thread,
        () => params['modelProvider'] as String? ?? 'openai',
      );
    }
    final result = switch (method) {
      'initialize' => <String, Object?>{'userAgent': 'codex/0.166.0 (test)'},
      'config/read' => <String, Object?>{
        'config': <String, Object?>{},
        'layers': [
          {
            'name': {
              'type': 'user',
              'file': '${h.home.path}${Platform.pathSeparator}config.toml',
            },
          },
        ],
      },
      'thread/start' || 'thread/resume' || 'thread/fork' => <String, Object?>{
        'thread': {
          'id': thread,
          'modelProvider': h.threadProviders[thread],
          'turns': <Object?>[],
        },
      },
      'turn/start' => <String, Object?>{
        'turn': {'id': 'server-turn-${++turns}'},
      },
      _ => <String, Object?>{},
    };
    _reply({'id': message['id'], 'result': result});
  }

  void _reply(Map<String, Object?> response) => scheduleMicrotask(() {
    if (!_messages.isClosed) _messages.add(response);
  });

  void notify(String method, Map<String, Object?> params) =>
      _messages.add({'method': method, 'params': params});

  @override
  void close() {
    closeRequested = true;
    h.changed();
    if (!delayExit) finishExit();
  }

  void finishExit() {
    if (_exited.isCompleted) return;
    h.writers.removeWhere((_, owner) => identical(owner, this));
    _exited.complete();
    h.changed();
    unawaited(_messages.close());
  }
}
