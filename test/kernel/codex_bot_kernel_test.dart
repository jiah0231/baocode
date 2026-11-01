import 'dart:async';

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
