import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/ide/ide_commands.dart' show ideUsesMacKeys;
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/main.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';

SessionRecord _record(String id) => SessionRecord(
  id: id,
  title: 'Chat $id',
  updatedAt: DateTime(2026, 10, id == 'source' ? 1 : 2),
  cwd: '/tmp/fork-test',
);

class _Catalog implements SessionCatalog {
  @override
  Future<List<ProjectRecord>> projects() async => [
    ProjectRecord(
      path: '/tmp/fork-test',
      sessions: [_record('source'), _record('other')],
    ),
  ];
  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => [];
  @override
  Future<void> delete(String id) async {}
}

/// No CLI, credentials or model calls. Requests go through the actual adapter.
class _Server implements CodexTransport {
  _Server(this.configPath);

  final String configPath;
  final _out = StreamController<Map<String, Object?>>.broadcast();
  final _exited = Completer<void>();
  final written = <Map<String, Object?>>[];
  String version = '0.166.0';
  String? forkId = 'forked';
  bool failFork = false;
  bool failResume = false;
  bool holdResume = false;
  bool holdTurn = false;
  Map<String, Object?>? pendingResume;
  Map<String, Object?>? pendingTurn;
  int turns = 0;
  @override
  Stream<Map<String, Object?>> get messages => _out.stream;
  @override
  Future<void> get exited => _exited.future;
  Iterable<Map<String, Object?>> requests(String method) =>
      written.where((message) => message['method'] == method);
  void push(Map<String, Object?> message) {
    if (!_out.isClosed) _out.add(message);
  }

  void respond(Map<String, Object?> message, Map<String, Object?> result) =>
      scheduleMicrotask(() => push({'id': message['id'], 'result': result}));
  Map<String, Object?> thread(String id) => {
    'thread': {
      'id': id,
      'modelProvider': 'openai',
      'turns': [
        {
          'id': 'historical-turn',
          'status': 'completed',
          'items': [
            {
              'type': 'userMessage',
              'id': 'historical-user',
              'content': [
                {'type': 'text', 'text': 'Kept question'},
              ],
            },
            {
              'type': 'agentMessage',
              'id': 'historical-answer',
              'text': 'Kept answer',
            },
          ],
        },
      ],
    },
  };
  void releaseResume() {
    final message = pendingResume!;
    pendingResume = null;
    respond(message, thread((message['params'] as Map)['threadId'] as String));
  }

  void releaseTurn() {
    final message = pendingTurn!;
    pendingTurn = null;
    respond(message, {
      'turn': {'id': 'server-turn-${++turns}'},
    });
  }

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final method = message['method'];
    if (method == null || message['id'] == null) return;
    final params = message['params'] as Map? ?? const {};
    if (method == 'thread/resume' && failResume) {
      scheduleMicrotask(
        () => push({
          'id': message['id'],
          'error': {'code': -32602, 'message': 'Resume rejected'},
        }),
      );
      return;
    }
    if (method == 'thread/resume' && holdResume) {
      pendingResume = message;
      return;
    }
    if (method == 'turn/start' && holdTurn) {
      pendingTurn = message;
      return;
    }
    if (method == 'thread/fork' && failFork) {
      scheduleMicrotask(
        () => push({
          'id': message['id'],
          'error': {'code': -32602, 'message': 'Fork rejected'},
        }),
      );
      return;
    }
    respond(message, switch (method) {
      'initialize' => {'userAgent': 'baocode/$version (test)'},
      // Initialization also loads custom prompts. Model the native user
      // config layer instead of generating an unrelated unavailable notice.
      'config/read' => {
        'config': <String, Object?>{},
        'layers': [
          {
            'name': {'type': 'user', 'file': configPath},
          },
        ],
      },
      'thread/resume' => thread(params['threadId'] as String),
      'thread/start' => thread('new-source'),
      'thread/fork' =>
        forkId == null ? {'thread': <String, Object?>{}} : thread(forkId!),
      'turn/start' => {
        'turn': {'id': 'server-turn-${++turns}'},
      },
      _ => <String, Object?>{},
    });
  }

  @override
  void close() {
    if (!_out.isClosed) unawaited(_out.close());
    if (!_exited.isCompleted) _exited.complete();
  }
}

class _Harness {
  _Harness() {
    final home = Directory.systemTemp.createTempSync('baocode-fork-config-');
    addTearDown(() => home.delete(recursive: true));
    descriptor = KernelDescriptor(
      id: 'codex',
      label: 'Codex',
      icon: Icons.code,
      description: '',
      catalog: _Catalog(),
      create: (context) {
        final server = _Server(
          '${home.path}${Platform.pathSeparator}config.toml',
        );
        configureServer?.call(server);
        servers.add(server);
        final kernel = CodexKernel(
          descriptor,
          context,
          start: (_) async => server,
          providers: providers,
          providerProxy: () async => null,
        );
        kernels.add(kernel);
        return kernel;
      },
    );
  }
  final providers = ModelProviders.memory(providers: []);
  void Function(_Server)? configureServer;
  final servers = <_Server>[];
  final kernels = <CodexKernel>[];
  late final KernelDescriptor descriptor;
  ChatSession session({bool resume = true}) => ChatSession(
    kernel: descriptor,
    kernels: [descriptor],
    historyCount: 0,
    kernelContext: KernelContext(
      cwd: '/tmp/fork-test',
      resume: resume ? _record('source') : null,
    ),
  );
}

List<ChatItem> _items(ChatSession session) => [
  for (var i = 0; i < session.itemCount; i++) session.itemAt(i),
];

void main() {
  test('a new empty chat cannot fork or create a server session', () async {
    final h = _Harness();
    final session = h.session(resume: false);
    addTearDown(session.dispose);
    expect(session.canFork, isFalse);
    expect(await session.fork(title: 'copy'), isNull);
    expect(h.servers.single.written, isEmpty);
  });

  test(
    'cold history forks without resuming or starting work in the source',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      expect(session.canFork, isTrue);
      final record = await session.fork(title: 'copy');
      expect(record?.id, 'forked');
      expect(session.sessionId, 'source');
      expect(_items(session), isEmpty);
      final server = h.servers.single;
      expect(server.requests('thread/resume'), isEmpty);
      expect(server.requests('turn/start'), isEmpty);
      expect(server.requests('thread/fork').single['params'], {
        'threadId': 'source',
        'deferGoalContinuation': true,
      });
      expect(server.requests('thread/name/set').single['params'], {
        'threadId': 'forked',
        'name': 'copy',
      });
      expect(server.requests('thread/revert'), isEmpty);
      expect(server.requests('thread/rollback'), isEmpty);
    },
  );

  test(
    'source can resume and continue after a cold fork without a view',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      final server = h.servers.single;
      expect((await session.fork(title: 'copy'))?.id, 'forked');
      expect(server.requests('thread/resume'), isEmpty);
      expect(server.requests('turn/start'), isEmpty);
      h.kernels.single.prepare();
      await pumpEventQueue();
      expect(server.requests('thread/resume'), hasLength(1));
      expect(
        _items(session).whereType<UserMessageItem>().single.text,
        'Kept question',
      );
      session.send(const ComposerMessage(text: 'Continue original'));
      await pumpEventQueue();
      expect(server.requests('thread/resume'), hasLength(1));
      expect(
        (server.requests('turn/start').single['params'] as Map)['threadId'],
        'source',
      );
      expect(session.sessionId, 'source');
      expect(session.isStreaming, isTrue);
    },
  );

  test(
    'cold fork child notifications cannot rename or mutate the source',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      final server = h.servers.single;
      expect((await session.fork(title: 'copy'))?.id, 'forked');
      final used = session.context?.used;
      final window = session.context?.window;
      server.push({
        'method': 'thread/name/updated',
        'params': {'threadId': 'forked', 'threadName': 'Child only'},
      });
      server.push({
        'method': 'thread/tokenUsage/updated',
        'params': {
          'threadId': 'forked',
          'tokenUsage': {
            'modelContextWindow': 32000,
            'last': {'totalTokens': 9000},
          },
        },
      });
      server.push({
        'method': 'item/agentMessage/delta',
        'params': {
          'threadId': 'forked',
          'itemId': 'child-message',
          'delta': 'Child text',
        },
      });
      await pumpEventQueue();
      expect(server.requests('thread/resume'), isEmpty);
      expect(session.takeRenamed(), isNull);
      expect(session.sessionId, 'source');
      expect(session.context?.used, used);
      expect(session.context?.window, window);
      expect(_items(session), isEmpty);
    },
  );

  for (final id in <String?>[null, '', 'source']) {
    test(
      'fork response with invalid separate identity $id is rejected',
      () async {
        final h = _Harness();
        final session = h.session();
        addTearDown(session.dispose);
        final server = h.servers.single..forkId = id;
        expect(await session.fork(title: 'copy'), isNull);
        expect(session.sessionId, 'source');
        expect(_items(session).whereType<NoticeItem>(), isNotEmpty);
        expect(server.requests('thread/name/set'), isEmpty);
        expect(server.requests('thread/resume'), isEmpty);
      },
    );
  }

  test(
    'a second cold fork waits for a subsequently started source resume',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      final server = h.servers.single;
      expect((await session.fork(title: 'first copy'))?.id, 'forked');
      expect(server.requests('thread/resume'), isEmpty);
      server.holdResume = true;
      h.kernels.single.prepare();
      await pumpEventQueue();
      expect(server.pendingResume, isNotNull);
      var completed = false;
      final second = session.fork(title: 'second copy').then((value) {
        completed = true;
        return value;
      });
      await pumpEventQueue();
      expect(completed, isFalse);
      expect(server.requests('thread/fork'), hasLength(1));
      server.releaseResume();
      expect((await second)?.id, 'forked');
      expect(server.requests('thread/fork'), hasLength(2));
      expect(server.requests('thread/resume'), hasLength(1));
      expect(session.sessionId, 'source');
    },
  );

  test(
    'child command approvals are rejected without prompting in the source',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      final server = h.servers.single;
      expect((await session.fork(title: 'copy'))?.id, 'forked');
      server.push({
        'id': 'child-approval',
        'method': 'item/commandExecution/requestApproval',
        'params': {
          'threadId': 'forked',
          'turnId': 'child-turn',
          'itemId': 'child-command',
          'command': 'echo child',
        },
      });
      await pumpEventQueue();
      final response = server.written.singleWhere(
        (message) => message['id'] == 'child-approval',
      );
      expect((response['error'] as Map)['code'], -32602);
      expect(response.containsKey('result'), isFalse);
      expect(session.pendingInteraction, isNull);
      expect(session.sessionId, 'source');
      expect(_items(session), isEmpty);
      expect(server.requests('thread/resume'), isEmpty);
    },
  );

  test(
    'source resume failure after cold fork is surfaced in kernel health',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      final server = h.servers.single;
      expect((await session.fork(title: 'copy'))?.id, 'forked');
      server.failResume = true;
      final kernel = h.kernels.single;
      kernel.prepare();
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.failed);
      expect(kernel.health.message, contains('resume'));
      expect(kernel.health.detail, contains('Resume rejected'));
      expect(session.sessionId, 'source');
      expect(server.requests('turn/start'), isEmpty);
    },
  );

  test(
    'fork waits for a pending resume rather than using an absent thread',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      final server = h.servers.single..holdResume = true;
      h.kernels.single.prepare();
      await pumpEventQueue();
      expect(server.pendingResume, isNotNull);
      var completed = false;
      final fork = session.fork(title: 'copy').then((value) {
        completed = true;
        return value;
      });
      await pumpEventQueue();
      expect(completed, isFalse);
      expect(server.requests('thread/fork'), isEmpty);
      server.releaseResume();
      expect((await fork)?.id, 'forked');
    },
  );

  test(
    'running fork excludes the active native turn and leaves source running',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      h.kernels.single.prepare();
      await pumpEventQueue();
      session.send(const ComposerMessage(text: 'Still working'));
      await pumpEventQueue();
      final sourceItems = _items(session)
          .where((item) => item is! LiveStatusItem)
          .toList();
      expect(session.isStreaming, isTrue);
      expect(session.canFork, isTrue);
      final record = await session.fork(title: 'copy');
      expect(record?.id, 'forked');
      expect(h.servers.single.requests('thread/fork').single['params'], {
        'threadId': 'source',
        'beforeTurnId': 'server-turn-1',
        'deferGoalContinuation': true,
      });
      expect(session.sessionId, 'source');
      expect(session.isStreaming, isTrue);
      expect(
        _items(session).where((item) => item is! LiveStatusItem),
        sourceItems,
      );
      expect(h.servers.single.requests('turn/interrupt'), isEmpty);
      expect(h.servers.single.requests('thread/revert'), isEmpty);
    },
  );

  test(
    'native goal turns without a user message are excluded from a fork',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      h.kernels.single.prepare();
      await pumpEventQueue();
      final server = h.servers.single;
      server.push({
        'method': 'turn/started',
        'params': {
          'threadId': 'source',
          'turn': {'id': 'native-goal-turn'},
        },
      });
      await pumpEventQueue();
      expect(session.isStreaming, isTrue);
      expect((await session.fork(title: 'copy'))?.id, 'forked');
      expect(server.requests('thread/fork').single['params'], {
        'threadId': 'source',
        'beforeTurnId': 'native-goal-turn',
        'deferGoalContinuation': true,
      });
      expect(session.isStreaming, isTrue);
      expect(server.requests('turn/interrupt'), isEmpty);
    },
  );

  test(
    'completing a turn while fork starts does not erase its cutoff',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      h.kernels.single.prepare();
      await pumpEventQueue();
      session.send(const ComposerMessage(text: 'Working'));
      await pumpEventQueue();
      final server = h.servers.single;
      final fork = session.fork(title: 'copy');
      server.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'source',
          'turn': {'id': 'server-turn-1', 'status': 'completed'},
        },
      });
      expect((await fork)?.id, 'forked');
      expect(
        (server.requests('thread/fork').single['params']
            as Map)['beforeTurnId'],
        'server-turn-1',
      );
      expect(session.sessionId, 'source');
    },
  );

  test(
    'an unresolved running turn cannot silently become a whole fork',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      final server = h.servers.single;
      h.kernels.single.prepare();
      await pumpEventQueue();
      server.holdTurn = true;
      session.send(const ComposerMessage(text: 'Starting'));
      await pumpEventQueue();
      expect(server.pendingTurn, isNotNull);
      expect(await session.fork(title: 'unsafe copy'), isNull);
      expect(server.requests('thread/fork'), isEmpty);
      expect(_items(session).whereType<NoticeItem>(), isNotEmpty);
      expect(session.isStreaming, isTrue);
      server.releaseTurn();
      await pumpEventQueue();
    },
  );

  test(
    'older servers reject bounded fork safely but still allow idle copies',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      final server = h.servers.single..version = '0.165.0';
      h.kernels.single.prepare();
      await pumpEventQueue();
      session.send(const ComposerMessage(text: 'Working'));
      await pumpEventQueue();
      expect(await session.fork(title: 'unsafe copy'), isNull);
      expect(server.requests('thread/fork'), isEmpty);
      expect(_items(session).whereType<NoticeItem>(), isNotEmpty);
      server.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'source',
          'turn': {'id': 'server-turn-1', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      expect((await session.fork(title: 'safe copy'))?.id, 'forked');
      expect(
        (server.requests('thread/fork').single['params'] as Map).containsKey(
          'beforeTurnId',
        ),
        isFalse,
      );
    },
  );

  for (final version in ['unknown', '0.166.0-alpha.1', '0.167.0']) {
    test('running boundary capability is conservative for $version', () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      final server = h.servers.single..version = version;
      h.kernels.single.prepare();
      await pumpEventQueue();
      session.send(const ComposerMessage(text: 'Working'));
      await pumpEventQueue();
      final fork = await session.fork(title: 'copy');
      if (version == '0.167.0') {
        expect(fork?.id, 'forked');
        expect(
          (server.requests('thread/fork').single['params']
              as Map)['beforeTurnId'],
          'server-turn-1',
        );
      } else {
        expect(fork, isNull);
        expect(server.requests('thread/fork'), isEmpty);
        expect(_items(session).whereType<NoticeItem>(), isNotEmpty);
      }
      expect(session.sessionId, 'source');
      expect(session.isStreaming, isTrue);
    });
  }

  test(
    'RPC failure is visible and never rewinds or replaces the source',
    () async {
      final h = _Harness();
      final session = h.session();
      addTearDown(session.dispose);
      final server = h.servers.single..failFork = true;
      expect(await session.fork(title: 'copy'), isNull);
      expect(session.sessionId, 'source');
      expect(_items(session).whereType<NoticeItem>(), isNotEmpty);
      expect(server.requests('thread/revert'), isEmpty);
      expect(server.requests('thread/rollback'), isEmpty);
    },
  );

  test(
    'workspace copies chosen mode and permissions, not the source identity',
    () async {
      final h = _Harness();
      final workspace = Workspace(
        kernels: [h.descriptor],
        preferences: MemoryPreferenceStore(),
      );
      addTearDown(workspace.dispose);
      await workspace.load();
      final source = workspace.threads.firstWhere(
        (thread) => thread.id == 'source',
      );
      final session = source.session;
      final permissions = session.permissions!;
      permissions.onSelected(
        permissions.options.firstWhere((option) => option.id == 'read-only'),
      );
      final modes = session.modes!;
      modes.onSelected(
        modes.options.firstWhere((option) => option.id == 'plan'),
      );
      final fork = await workspace.fork(source);
      expect(fork, isNotNull);
      expect(fork!.id, 'forked');
      expect(source.id, 'source');
      expect(fork.project, same(source.project));
      expect(fork.session.selected(KernelChoiceKind.mode), 'plan');
      expect(fork.session.selected(KernelChoiceKind.permission), 'read-only');
      expect(session.selected(KernelChoiceKind.mode), 'plan');
      expect(session.selected(KernelChoiceKind.permission), 'read-only');
    },
  );

  Finder row(String title) =>
      find.descendant(of: find.byType(Sidebar), matching: find.text(title));
  Future<Workspace> app(WidgetTester tester, _Harness h) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final workspace = Workspace(
      kernels: [h.descriptor],
      preferences: MemoryPreferenceStore(),
    );
    await tester.pumpWidget(BaoCodeApp(workspace: workspace));
    await tester.runAsync(workspace.load);
    await tester.pump();
    return workspace;
  }

  // Prompt discovery uses real filesystem I/O. Pumping a fixed number of
  // microtasks does not establish completion on a Windows runner.
  Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
    final clock = Stopwatch()..start();
    while (!done() && clock.elapsed < const Duration(seconds: 10)) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump();
    expect(
      done(),
      isTrue,
      reason: 'The requested asynchronous UI transition did not complete',
    );
  }

  testWidgets(
    'cold sidebar menu forks into a usable independent conversation',
    (tester) async {
      final h = _Harness();
      final workspace = await app(tester, h);
      final source = workspace.threads.firstWhere(
        (thread) => thread.id == 'source',
      );
      expect(source.isOpen, isFalse);
      await tester.tap(row('Chat source'), buttons: kSecondaryButton);
      await tester.pump();
      expect(find.text('Fork'), findsOneWidget);
      await tester.tap(find.text('Fork'));
      await pumpUntil(
        tester,
        () => workspace.threads.any((thread) => thread.id == 'forked'),
      );
      final fork = workspace.threads.singleWhere(
        (thread) => thread.id == 'forked',
      );
      expect(source.id, 'source');
      expect(fork.title, 'Chat source (fork)');
      expect(fork.kernel, source.kernel);
      expect(fork.project, source.project);
      for (final kind in KernelChoiceKind.values.where(
        (kind) => kind != KernelChoiceKind.fast,
      )) {
        expect(fork.session.selected(kind), source.session.selected(kind));
      }
      await pumpUntil(
        tester,
        () => h.kernels.any(
          (kernel) =>
              kernel.sessionId == 'forked' &&
              kernel.health.status == KernelHealthStatus.ready,
        ),
      );
      fork.session.send(const ComposerMessage(text: 'Continue the copy'));
      await pumpUntil(
        tester,
        () =>
            h.servers.any((server) => server.requests('turn/start').isNotEmpty),
      );
      final sends = h.servers
          .expand((server) => server.requests('turn/start'))
          .toList();
      expect(sends, hasLength(1));
      expect((sends.single['params'] as Map)['threadId'], 'forked');
      expect(source.session.isStreaming, isFalse);
      expect(_items(source.session), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cold sidebar fork failure opens the source and shows its error',
    (tester) async {
      final h = _Harness()
        ..configureServer = (server) => server.failFork = true;
      final workspace = await app(tester, h);
      final source = workspace.threads.firstWhere(
        (thread) => thread.id == 'source',
      );
      expect(source.isOpen, isFalse);
      await tester.tap(row('Chat source'), buttons: kSecondaryButton);
      await tester.pump();
      await tester.tap(find.text('Fork'));
      await pumpUntil(
        tester,
        () =>
            identical(workspace.current, source) &&
            _items(source.session).whereType<NoticeItem>().isNotEmpty,
      );
      expect(
        workspace.threads.where((thread) => thread.id == 'forked'),
        isEmpty,
      );
      expect(workspace.current, same(source));
      expect(source.id, 'source');
      expect(find.textContaining('Fork rejected'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('running sidebar conversation keeps Fork available', (
    tester,
  ) async {
    final h = _Harness();
    final workspace = await app(tester, h);
    await tester.tap(row('Chat source'));
    await pumpUntil(
      tester,
      () => h.kernels.any(
        (kernel) =>
            kernel.sessionId == 'source' &&
            kernel.health.status == KernelHealthStatus.ready,
      ),
    );
    final source = workspace.threads.firstWhere(
      (thread) => thread.id == 'source',
    );
    source.session.send(const ComposerMessage(text: 'Working in the source'));
    await pumpUntil(
      tester,
      () => h.servers.any((server) => server.requests('turn/start').isNotEmpty),
    );
    expect(source.session.isStreaming, isTrue);
    await tester.tap(row('Chat source'), buttons: kSecondaryButton);
    await tester.pump();
    expect(find.text('Fork'), findsOneWidget);
    await tester.tap(find.text('Fork'));
    await pumpUntil(
      tester,
      () => workspace.threads.any((thread) => thread.id == 'forked'),
    );
    expect(
      workspace.threads.where((thread) => thread.id == 'forked'),
      hasLength(1),
    );
    final request = h.servers
        .expand((server) => server.requests('thread/fork'))
        .single;
    expect((request['params'] as Map)['beforeTurnId'], 'server-turn-1');
    expect(source.session.isStreaming, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('multi-selected sidebar conversations have no Fork action', (
    tester,
  ) async {
    final h = _Harness();
    await app(tester, h);
    await tester.tap(row('Chat source'));
    await tester.pump();
    final modifier = ideUsesMacKeys
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.tap(row('Chat other'));
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
    await tester.tap(row('Chat other'), buttons: kSecondaryButton);
    await tester.pump();
    expect(find.text('Fork'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
