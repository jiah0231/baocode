import 'dart:async';

import 'package:baocode/chat/session_query.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

class _Server implements CodexTransport {
  final controller = StreamController<Map<String, Object?>>.broadcast();
  final written = <Map<String, Object?>>[];
  final done = Completer<void>();
  bool configAvailable = true;
  String? userAgent = 'baocode/0.166.0 (Windows 10; x86_64)';
  @override
  Stream<Map<String, Object?>> get messages => controller.stream;
  @override
  Future<void> get exited => done.future;
  @override
  void close() {
    controller.close();
    if (!done.isCompleted) done.complete();
  }

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    if (message['method'] == null) return;
    final result = switch (message['method']) {
      'initialize' => {'userAgent': userAgent},
      'config/read' =>
        configAvailable
            ? {
                'config': {
                  'mcp_servers': {
                    'external': {'enabled': true},
                  },
                  'features': {'shell_tool': true, 'hooks': true},
                  'profiles': {
                    'work': {
                      'features': {'shell_tool': true},
                    },
                  },
                },
              }
            : <String, Object?>{},
      'thread/start' || 'thread/resume' => {
        'thread': {'id': 'thread'},
      },
      'turn/start' => {
        'turn': {'id': 'turn'},
      },
      _ => <String, Object?>{},
    };
    scheduleMicrotask(() {
      if (!controller.isClosed) {
        controller.add({'id': message['id'], 'result': result});
      }
    });
  }

  void request(int id, String method, Map<String, Object?> params) =>
      controller.add({'id': id, 'method': method, 'params': params});
}

void main() {
  late _Server server;
  late CodexKernel kernel;
  var calls = 0;
  setUp(() {
    calls = 0;
    server = _Server();
    kernel = CodexKernel.withTransport(
      MockKernels.codex,
      server,
      context: KernelContext(
        cwd: '/bot',
        settings: const {'permission': 'danger-full-access'},
        workspace: () => const KernelWorkspace(
          folders: [],
          instructions: 'bot rules',
          ownPrompt: true,
          tools: [],
        ),
      ),
    );
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'bot_probe',
        description: '',
        inputSchema: {},
        run: (_, _) async {
          calls++;
          return 'ok';
        },
      ),
    );
  });
  tearDown(() {
    kernel.dispose();
    ClaudeSdkTools.unregister('bot_probe');
  });

  Future<void> begin() async {
    kernel.send(const KernelTurn(id: 'ours', text: 'hello'));
    await pumpEventQueue(times: 50);
  }

  for (final hasWorkspace in [false, true]) {
    test('ordinary chat registers and invokes tools (workspace=$hasWorkspace)', () async {
      kernel.dispose();
      server = _Server();
      kernel = CodexKernel.withTransport(
        MockKernels.codex,
        server,
        context: KernelContext(
          cwd: '/ordinary',
          workspace: hasWorkspace
              ? () => const KernelWorkspace(folders: [], instructions: 'project rules')
              : null,
        ),
      );
      await begin();
      final params = server.written.firstWhere(
        (m) => m['method'] == 'thread/start',
      )['params'] as Map;
      final names = (params['dynamicTools'] as List)
          .map((tool) => (tool as Map)['name']);
      expect(names, containsAll(['baocode_dispatch', 'bot_probe']));
      expect(params['sandbox'], isNot('read-only'));
      server.request(910, 'item/tool/call', {
        'threadId': 'thread', 'turnId': 'turn', 'callId': 'ordinary-call',
        'tool': 'bot_probe', 'arguments': {},
      });
      server.request(911, 'item/tool/call', {
        'threadId': 'foreign', 'turnId': 'turn', 'callId': 'foreign-call',
        'tool': 'bot_probe', 'arguments': {},
      });
      await pumpEventQueue();
      expect(calls, 1);
      expect((server.written.firstWhere((m) => m['id'] == 910)['result'] as Map)['success'], true);
      expect((server.written.firstWhere((m) => m['id'] == 911)['result'] as Map)['success'], false);
    });
  }

  test('ordinary transport retrieves only selected Claude conversation', () async {
    kernel.dispose();
    server = _Server();
    kernel = CodexKernel.withTransport(
      MockKernels.codex,
      server,
      context: const KernelContext(cwd: '/ordinary'),
    );
    final reads = <String>[];
    final queries = SessionQueryService(read: (id) async {
      reads.add(id);
      return SessionQuerySnapshot(
        targetId: id, title: 'Claude task', kernel: 'Claude Code',
        messages: const [SessionQueryMessage(
          index: 0, role: 'assistant', text: 'The port is 8123.',
        )],
      );
    })..register();
    addTearDown(queries.dispose);
    final capability = queries.grant(
      ['claude-code:target'], callerSessionId: () => kernel.sessionId,
    );
    await begin();
    final start = server.written.firstWhere(
      (m) => m['method'] == 'thread/start',
    )['params'] as Map;
    expect((start['dynamicTools'] as List).map((t) => (t as Map)['name']),
        contains('session_query'));
    for (final (rpc, target) in [(913, 'claude-code:target'), (914, 'claude-code:secret')]) {
      server.request(rpc, 'item/tool/call', {
        'threadId': 'thread', 'turnId': 'turn', 'callId': 'query-$rpc',
        'tool': 'session_query',
        'arguments': {'capability': capability, 'session_id': target},
      });
    }
    await pumpEventQueue();
    expect(reads, ['claude-code:target']);
    final answer = server.written.firstWhere((m) => m['id'] == 913)['result'] as Map;
    expect(answer['success'], true);
    expect(answer['contentItems'].toString(), contains('8123'));
    expect((server.written.firstWhere((m) => m['id'] == 914)['result'] as Map)['success'], false);
  });

  test('resumed ordinary chat serves persisted dispatcher with current registry', () async {
    kernel.dispose();
    server = _Server();
    kernel = CodexKernel.withTransport(
      MockKernels.codex,
      server,
      context: KernelContext(
        cwd: '/ordinary',
        resume: SessionRecord(id: 'thread', title: 'Saved', updatedAt: DateTime(2026)),
      ),
    );
    await begin();
    final params = server.written.firstWhere(
      (m) => m['method'] == 'thread/resume',
    )['params'] as Map;
    // Existing dispatcher metadata is restored by app-server, not replaced
    // by an unsupported dynamicTools argument on resume.
    expect(params.containsKey('dynamicTools'), false);
    server.request(912, 'item/tool/call', {
      'threadId': 'thread', 'turnId': 'turn', 'callId': 'resumed-call',
      'tool': 'baocode_dispatch',
      'arguments': {'operation': 'call', 'name': 'bot_probe', 'arguments': {}},
    });
    await pumpEventQueue();
    expect(calls, 1);
    expect((server.written.firstWhere((m) => m['id'] == 912)['result'] as Map)['success'], true);
  });

  test('bot thread uses dynamic tools and isolated restrictions even with full-access choice', () async {
    await begin();
    final params =
        server.written.firstWhere(
              (m) => m['method'] == 'thread/start',
            )['params']
            as Map;
    expect(params['sandbox'], 'read-only');
    expect(params['approvalPolicy'], 'never');
    expect(params['baseInstructions'], contains('bot rules'));
    expect(params['dynamicTools'], isNotEmpty);
    final config = params['config'] as Map;
    expect(config['mcp_servers'], {
      'external': {'enabled': false},
    });
    expect((config['features'] as Map)['hooks'], isFalse);
    expect(
      (((config['profiles'] as Map)['work'] as Map)['features']
          as Map)['shell_tool'],
      isFalse,
    );
    final turn =
        server.written.firstWhere((m) => m['method'] == 'turn/start')['params']
            as Map;
    expect(turn['sandboxPolicy'], {'type': 'readOnly'});
    expect(
      server.written.any((m) => m['method'] == 'config/value/write'),
      isFalse,
    );
  });

  test(
    'valid tool runs, foreign and inactive requests have no side effects',
    () async {
      await begin();
      Map<String, Object?> params(String thread, String turn) => {
        'threadId': thread,
        'turnId': turn,
        'callId': 'call',
        'tool': 'bot_probe',
        'arguments': {},
      };
      server.request(900, 'item/tool/call', params('other', 'turn'));
      server.request(901, 'item/tool/call', params('thread', 'other'));
      server.request(902, 'item/tool/call', params('thread', 'turn'));
      server.request(903, 'item/commandExecution/requestApproval', {
        'threadId': 'thread',
        'turnId': 'turn',
      });
      await pumpEventQueue();
      expect(calls, 1);
      expect(
        (server.written.firstWhere((m) => m['id'] == 900)['result']
            as Map)['success'],
        isFalse,
      );
      expect(
        (server.written.firstWhere((m) => m['id'] == 902)['result']
            as Map)['success'],
        isTrue,
      );
      expect(
        server.written.firstWhere((m) => m['id'] == 903)['error'],
        isNotNull,
      );
      kernel.cancel();
      await pumpEventQueue();
      server.request(904, 'item/tool/call', params('thread', 'turn'));
      await pumpEventQueue();
      expect(calls, 1);
    },
  );

  for (final version in [
    null,
    'baocode/0.165.0 (Windows)',
    'baocode/0.167.0 (Windows)',
    'unknown',
  ]) {
    test(
      'unsupported bot version $version fails before starting a thread',
      () async {
        server.userAgent = version;
        await begin();
        expect(
          server.written.any((m) => m['method'] == 'thread/start'),
          isFalse,
        );
        expect(server.written.any((m) => m['method'] == 'turn/start'), isFalse);
      },
    );
  }

  test('unreadable configuration fails closed before thread start', () async {
    server.configAvailable = false;
    await begin();
    expect(server.written.any((m) => m['method'] == 'thread/start'), isFalse);
    expect(server.written.any((m) => m['method'] == 'turn/start'), isFalse);
  });
}
