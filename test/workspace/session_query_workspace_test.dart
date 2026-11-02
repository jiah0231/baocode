import 'dart:async';
import 'dart:convert';

import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/composer/suggestion_menu.dart';
import 'package:baocode/chat/composer/composer_embeds.dart';
import 'package:baocode/main.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../composer_test.dart' show typeInto;

class _Catalog implements SessionCatalog, SessionHistoryCatalog {
  _Catalog(this.id);
  final String id;
  int reads = 0;
  bool oversized = false;
  String? oversizedText;
  final readIds = <String>[];
  bool paged = false;
  final cursors = <String?>[];

  @override
  Future<SessionTextPage> readTextPage(SessionRecord session, {String? cursor}) async {
    reads++;
    readIds.add(session.id);
    if (oversized) {
      return SessionTextPage(messages: [
        const SessionTextMessage(role: 'assistant', text: 'Earlier port 7000', id: 'old'),
        SessionTextMessage(role: 'assistant', id: 'large',
            text: oversizedText ?? 'Important port 9000. ${List.filled(200010, 'x').join()}'),
      ]);
    }
    cursors.add(cursor);
    if (cursor == 'older-1') {
      return SessionTextPage(
        messages: [
          for (var i = 0; i < 10; i++)
            SessionTextMessage(role: 'assistant', text: 'Older port $i'),
        ],
        nextCursor: 'older-2',
      );
    }
    if (cursor == 'older-2') {
      return const SessionTextPage(messages: [
        SessionTextMessage(role: 'assistant', text: 'Oldest port 7000'),
      ]);
    }
    return SessionTextPage(messages: const [
      SessionTextMessage(role: 'user', text: 'What is the chosen port?', id: 'user-1'),
      SessionTextMessage(role: 'assistant', text: 'Use port 8123.', id: 'answer-1'),
    ], nextCursor: paged ? 'older-1' : null);
  }

  @override
  Future<List<ProjectRecord>> projects() async => [
    ProjectRecord(path: '/tmp/session-query', sessions: [
      SessionRecord(
        id: id,
        title: 'Task $id',
        updatedAt: DateTime(2026, 11, 1),
        cwd: '/tmp/session-query',
      ),
    ]),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];

  @override
  Future<void> delete(String id) async {}
}

class _Kernel implements AgentKernel, PreparesConversation, QueuesMessages {
  _Kernel(this.descriptor, this.sessionId);
  @override
  final KernelDescriptor descriptor;
  @override
  String? sessionId;
  final controller = StreamController<KernelEvent>.broadcast(sync: true);
  final sent = <KernelTurn>[];
  int seq = 0;
  int prepares = 0;
  int cancellations = 0;

  @override
  Stream<KernelEvent> get events => controller.stream;
  @override
  KernelHealth get health => KernelHealth.ready;
  @override
  Future<void> get stopped async {}
  @override
  void send(KernelTurn turn) {
    sent.add(turn);
    controller.add(ItemUpserted(
      ++seq, turn.id, UserMessageItem(text: turn.text, queued: true),
    ));
  }
  void start(String turnId) {
    final turn = sent.firstWhere((turn) => turn.id == turnId);
    controller.add(TurnStarted(++seq, turnId));
    controller.add(ItemUpserted(
      ++seq, turnId, UserMessageItem(text: turn.text),
    ));
  }

  @override
  Future<bool> cancelQueued(String turnId) async {
    controller.add(ItemRemoved(++seq, turnId));
    return true;
  }
  @override
  void sendQueuedNow(String turnId) {}
  @override
  void moveQueued(String turnId, int index) {}
  @override
  void answer(String requestId, InteractionAnswer answer) {}
  @override
  void cancel() => cancellations++;
  @override
  void restart() {}
  @override
  void prepare() {}
  @override
  void release() {}
  @override
  void dispose() => unawaited(controller.close());

  @override
  Future<bool> prepareConversation() async {
    if (prepares++ == 0) {
      controller.add(HistoryPrepended(++seq, const [
        ('user-1', UserMessageItem(text: 'What is the chosen port?')),
        ('answer-1', AssistantTextItem('Use port 8123.')),
      ]));
    }
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Workspace workspace;
  late Map<String, _Kernel> kernels;
  late Map<String, _Catalog> catalogs;
  late AgentThread source;
  late AgentThread target;
  var hostedByApp = false;

  setUp(() async {
    hostedByApp = false;
    kernels = {};
    catalogs = {};
    KernelDescriptor descriptor(String id, String label, String sessionId) {
      late final KernelDescriptor value;
      value = KernelDescriptor(
        id: id,
        label: label,
        icon: const IconData(0xe001),
        description: '',
        catalog: catalogs[sessionId] = _Catalog(sessionId),
        create: (context) {
          final key = context.resume?.id ?? 'new-$id';
          return kernels[key] = _Kernel(value, key);
        },
      );
      return value;
    }

    workspace = Workspace(kernels: [
      descriptor('codex', 'Codex', 'source'),
      descriptor('claude-code', 'Claude Code', 'target'),
    ]);
    await workspace.load();
    source = workspace.threads.firstWhere((thread) => thread.id == 'source');
    target = workspace.threads.firstWhere((thread) => thread.id == 'target');
    // Open the source only. Queries must load the target lazily without send.
    expect(source.session.sessionQueries, same(workspace.sessionQueries));
  });
  tearDown(() {
    if (!hostedByApp) workspace.dispose();
  });

  String grant({List<String> ids = const ['claude-code:target'], bool start = true}) {
    source.session.send(ComposerMessage(
      text: 'What port did the other session choose?',
      sessionMentions: ids,
    ));
    final kernel = kernels['source']!;
    final turn = kernel.sent.last;
    expect(turn.notes.join(), isNot(contains('sq_')));
    expect(turn.notes.join(), isNot(contains('capability=')));
    if (start) kernel.start(turn.id);
    return turn.id;
  }

  Future<Map<String, dynamic>> query(String turnId, {
    String caller = 'source',
    String targetId = 'claude-code:target',
    bool older = false,
    int? before,
  }) async {
    final tool = ClaudeSdkTools.called('mcp__baocode__session_query')!;
    final result = await tool.run({
      'session_id': targetId,
      'query': 'port',
      if (older) 'older': true,
      'before': ?before,
    }, ClaudeSdkCall(cwd: '/tmp/session-query', sessionId: caller, turnId: turnId));
    return jsonDecode(result as String) as Map<String, dynamic>;
  }

  Future<void> showComposer(WidgetTester tester, AgentThread thread) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    workspace.select(thread);
    hostedByApp = true; // BaoCodeApp owns disposal of the supplied workspace.
    await tester.pumpWidget(BaoCodeApp(workspace: workspace));
    await tester.pump();
  }

  for (final reverse in [false, true]) {
    testWidgets('real @picker authorizes host-bound ${reverse ? 'Claude to Codex' : 'Codex to Claude'} query', (tester) async {
      final from = reverse ? target : source;
      final to = reverse ? source : target;
      await showComposer(tester, from);
      await typeInto(tester, find.byType(MarkdownEditor), 'Which port? @${to.id}');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.descendant(
        of: find.byType(SuggestionMenu), matching: find.text(to.title),
      ), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter); // accept actual picker row
      await tester.pump();
      final controller = tester.widget<MarkdownEditor>(find.byType(MarkdownEditor)).controller;
      final embed = composerPieces(controller.text).whereType<ComposerEmbed>().single;
      final targetId = '${to.kernel.id}:${to.id}';
      expect(ComposerTokenEmbed.selectedSession(embed.data), targetId);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter); // production composer submit
      await tester.pump();
      final kernel = kernels[from.id]!;
      expect(kernel.sent, hasLength(1));
      final turn = kernel.sent.single;
      expect(turn.notes.join(), contains('session_query'));
      expect(turn.notes.join(), isNot(contains('sq_')));
      expect(turn.notes.join(), isNot(contains('capability=')));
      kernel.start(turn.id); // transport's local active-turn boundary
      final result = await query(turn.id, caller: from.id!, targetId: targetId);
      expect((result['source'] as Map)['kernel'], to.kernel.label);
      expect((result['messages'] as List).last['text'], 'Use port 8123.');
      expect(kernels[to.id]?.sent ?? const [], isEmpty);
      from.session.stop();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('display-only session chip cannot authorize a host-bound query', (tester) async {
    await showComposer(tester, source);
    final editor = tester.widget<MarkdownEditor>(find.byType(MarkdownEditor));
    final text = '${ComposerTokenEmbed.session('claude-code:target', 'Task target').atom} ';
    editor.controller.replace(0, editor.controller.length, text,
        selection: TextSelection.collapsed(offset: text.length));
    editor.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    final kernel = kernels['source']!;
    final turn = kernel.sent.single;
    expect(turn.notes.join(), isNot(contains('session_query')));
    kernel.start(turn.id);
    await expectLater(query(turn.id), throwsStateError);
    source.session.stop();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('future queued selection is unavailable to the current host turn', () async {
    source.session.send(const ComposerMessage(text: 'Current request, no selection'));
    final kernel = kernels['source']!;
    final currentId = kernel.sent.last.id;
    kernel.start(currentId);
    final queuedId = grant(start: false);
    await expectLater(query(currentId), throwsStateError);
    // Even a stale/forged future-turn host value cannot activate a queued grant.
    await expectLater(query(queuedId), throwsStateError);
    kernel.controller.add(TurnEnded(++kernel.seq, currentId));
    kernel.start(queuedId);
    expect((await query(queuedId))['mode'], 'read_only_history');
  });

  test('explicit selection reads attributed cross-kernel history, never sends', () async {
    expect(target.isOpen, isFalse);
    final turnId = grant();
    final result = await query(turnId);
    expect(result['source'], {
      'session_id': 'claude-code:target',
      'title': 'Task target',
      'kernel': 'Claude Code',
    });
    expect(result['mode'], 'read_only_history');
    expect((result['messages'] as List).last['text'], 'Use port 8123.');
    expect(target.isOpen, isFalse);
    expect(kernels.containsKey('target'), isFalse);
    expect(catalogs['target']!.reads, 1);
    await query(turnId);
    expect(catalogs['target']!.reads, 1); // frozen snapshot
  });

  test('Claude source can query a Codex target through the same route', () async {
    target.session.send(const ComposerMessage(
      text: 'Read the other task',
      sessionMentions: ['codex:source'],
    ));
    final turnId = kernels['target']!.sent.last.id;
    kernels['target']!.start(turnId);
    final result = await query(turnId, caller: 'target', targetId: 'codex:source');
    expect((result['source'] as Map)['kernel'], 'Codex');
    expect(kernels['source']!.sent, isEmpty);
  });

  test('busy target is read without stopping or adding a turn', () async {
    await target.session.prepareConversation();
    final kernel = kernels['target']!;
    kernel.controller.add(TurnStarted(++kernel.seq, 'target-work'));
    final result = await query(grant());
    expect(result['target_busy'], isTrue);
    expect(kernel.sent, isEmpty);
    expect(kernel.cancellations, 0);
    expect(target.session.isStreaming, isTrue);
    expect(kernel.prepares, 1); // only the test's explicit setup
    expect(catalogs['target']!.reads, 1);
  });

  test('a provider-forked live ID never reads its stale sidebar record', () async {
    await target.session.prepareConversation();
    kernels['target']!.sessionId = 'forked-target';
    final turnId = grant(ids: ['claude-code:forked-target']);
    final result = await query(turnId, targetId: 'claude-code:forked-target');
    expect((result['source'] as Map)['session_id'], 'claude-code:forked-target');
    expect(catalogs['target']!.readIds, ['forked-target']);
  });

  test('oversized storage page continues within the page without losing older text', () async {
    catalogs['target']!.oversized = true;
    final turnId = grant();
    final first = await query(turnId);
    expect(first['messages'], isEmpty); // the tail has no matching keyword
    expect(first['truncated_window'], false);
    expect(first['next_history_available'], true);
    final rest = await query(turnId, older: true);
    final messages = rest['messages'] as List;
    expect(messages.map((m) => m['text']).join(' '), contains('Important port 9000'));
    expect(messages.map((m) => m['text']).join(' '), contains('Earlier port 7000'));
    expect(messages.last['start_character'], 0);
    expect(rest['next_history_available'], false);
    expect(catalogs['target']!.reads, 2);
  });

  test('literal queries spanning a large-message window boundary are found', () async {
    final catalog = catalogs['target']!..oversized = true;
    catalog.oversizedText = '${List.filled(200000, 'x').join()}'
        'port${List.filled(199998, 'x').join()}';
    final turnId = grant();
    final first = await query(turnId); // first window starts halfway through port
    expect(first['messages'], isEmpty);
    final next = await query(turnId, older: true);
    expect((next['messages'] as List).map((m) => m['text']).join(), contains('port'));
  });

  test('same-page continuation rejects changed history rather than shifting offsets', () async {
    catalogs['target']!.oversized = true;
    final turnId = grant();
    await query(turnId);
    catalogs['target']!.oversized = false;
    await expectLater(query(turnId, older: true), throwsA(isA<StateError>()
        .having((error) => error.message, 'message', contains('changed'))));
    expect(target.isOpen, isFalse);
  });

  test('older windows use internal cursors and negative before indexes', () async {
    final catalog = catalogs['target']!..paged = true;
    final turnId = grant();
    final newest = await query(turnId);
    expect(newest['next_history_available'], isTrue);
    expect(newest['messages'], hasLength(2));
    final older = await query(turnId, older: true);
    expect(older['messages'], hasLength(8));
    expect(older['next_before'], -8);
    expect(older['next_history_available'], isTrue);
    final remainder = await query(turnId, before: older['next_before'] as int);
    expect((remainder['messages'] as List).map((item) => item['index']), [-10, -9]);
    final oldest = await query(turnId, older: true);
    expect((oldest['messages'] as List).single['text'], 'Oldest port 7000');
    expect((oldest['messages'] as List).single['index'], -11);
    expect(oldest['next_history_available'], isFalse);
    expect(catalog.cursors, [null, 'older-1', 'older-2']);
    await expectLater(query(turnId, older: true), throwsStateError);
    expect(target.isOpen, isFalse);
  });

  test('plain references and empty selections create no capability', () {
    source.session.send(const ComposerMessage(
      text: '[Session claude-code:target: Task target]',
    ));
    expect(kernels['source']!.sent.last.notes, isEmpty);
    expect(target.isOpen, isFalse);
  });

  test('unknown, self and wrong-kernel selections cannot grant access', () {
    for (final id in ['missing', 'codex:source', 'codex:target']) {
      source.session.send(ComposerMessage(text: 'query', sessionMentions: [id]));
      final notes = kernels['source']!.sent.last.notes.join();
      expect(notes, contains('unavailable'));
      expect(notes, isNot(contains('sq_')));
    }
  });

  test('host turn authorization rejects another caller and an unselected target', () async {
    final turnId = grant();
    await expectLater(query(turnId, caller: 'target'), throwsStateError);
    await expectLater(query(turnId, targetId: 'codex:source'), throwsStateError);
    expect(target.isOpen, isFalse);
  });

  test('target archive revokes cached snapshot access', () async {
    final turnId = grant();
    await query(turnId);
    workspace.setArchived(target, true);
    await expectLater(query(turnId), throwsStateError);
  });

  test('turn end, queued cancellation and stop revoke grants', () async {
    var turnId = grant();
    final kernel = kernels['source']!;
    kernel.controller.add(TurnEnded(++kernel.seq, kernel.sent.last.id));
    await expectLater(query(turnId), throwsStateError);
    turnId = grant(start: false);
    source.session.cancelQueued(kernel.sent.last.id);
    await expectLater(query(turnId), throwsStateError);
    turnId = grant();
    kernel.controller.add(TurnStarted(++kernel.seq, kernel.sent.last.id));
    source.session.stop();
    await expectLater(query(turnId), throwsStateError);
  });

  test('ending one request preserves still-queued grants only', () async {
    final first = grant();
    final kernel = kernels['source']!;
    final firstId = kernel.sent.last.id;
    final queued = grant(start: false);
    final queuedId = kernel.sent.last.id;
    kernel.controller.add(TurnEnded(++kernel.seq, firstId));
    await expectLater(query(first), throwsStateError);
    kernel.start(queued);
    expect((await query(queued))['mode'], 'read_only_history');
    // A queued message taken into the active turn must not retain access after
    // that turn ends, even if the CLI does not give it a separate end event.
    kernel.controller.add(ItemUpserted(
      ++kernel.seq, queuedId, const UserMessageItem(text: 'taken into turn'),
    ));
    kernel.controller.add(TurnEnded(++kernel.seq, 'shared-active-turn'));
    await expectLater(query(queued), throwsStateError);
  });

  test('editing a local queued message preserves only its explicit selections', () async {
    final turnId = grant(start: false);
    final id = kernels['source']!.sent.last.id;
    await source.session.editQueued(id);
    expect(source.session.draft.pendingMessage?.sessionMentions,
        ['claude-code:target']);
    await expectLater(query(turnId), throwsStateError);
  });

  test('source disposal revokes its outstanding grants', () async {
    final turnId = grant();
    // Delete uses the workspace's normal disposal path, avoiding double dispose.
    workspace.delete(source);
    await expectLater(query(turnId), throwsStateError);
  });
}
