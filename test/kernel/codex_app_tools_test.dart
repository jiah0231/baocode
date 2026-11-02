import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/codex/codex_app_tools.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gate implements ClaudeSdkGate {
  bool allowed = true;
  @override
  bool offersTool(String cwd, String tool) => allowed && cwd == '/bot';
  @override
  bool tellsFeature(String cwd, String feature) => false;
  @override
  bool asksUser(String cwd) => false;
}

void main() {
  late _Gate gate;
  late CodexAppTools bridge;
  setUp(() {
    gate = _Gate();
    ClaudeSdkTools.gate = gate;
    bridge = CodexAppTools('/bot');
  });
  tearDown(() {
    bridge.cancel();
    ClaudeSdkTools.unregister('bot_probe');
    ClaudeSdkTools.unregister(ChatCodec.botImageTool);
    ClaudeSdkTools.gate = null;
  });

  Map<String, Object?> call([String name = 'bot_probe']) => {
    'threadId': 'thread',
    'turnId': 'turn',
    'callId': 'call',
    'namespace': null,
    'tool': name,
    'arguments': <String, Object?>{},
  };

  test('only the reviewed stable server family enables restricted bots', () {
    for (final value in [
      null,
      '',
      'baocode/0.165.9 (Windows)',
      'baocode/0.166.0-alpha.1',
      '1.2.3',
      'baocode/0.167.0',
      'codex-rs/1.0.0',
    ]) {
      expect(CodexAppTools.supportsRestrictedBots(value), isFalse);
    }
    for (final value in ['baocode/0.166.0 (Windows)', 'codex_cli_rs/0.166.1']) {
      expect(CodexAppTools.supportsRestrictedBots(value), isTrue);
    }
  });

  test('only offers gated tools and checks gate again at invocation', () async {
    var calls = 0;
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'bot_probe',
        description: 'probe',
        inputSchema: {'type': 'object'},
        run: (_, call) async {
          calls++;
          expect(call.toolUseId, 'call');
          expect(call.turnId, 'host-local-turn');
          return 'ok';
        },
      ),
    );
    expect(
      await bridge.specs(),
      contains(
        equals({
          'type': 'function',
          'name': 'bot_probe',
          'description': 'probe',
          'inputSchema': {'type': 'object'},
        }),
      ),
    );
    expect((await bridge.call(call(), threadId: 'thread', turnId: 'host-local-turn'))['success'], isTrue);
    gate.allowed = false;
    expect((await bridge.call(call(), threadId: 'thread'))['success'], isFalse);
    expect(calls, 1);
  });

  test('persistent dispatcher discovers newly granted tools and rechecks revocations', () async {
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'bot_probe',
        description: 'new capability',
        inputSchema: {},
        run: (_, _) async => 'called',
      ),
    );
    gate.allowed = false;
    final initial = await bridge.specs();
    expect(initial.map((t) => t['name']), contains('baocode_dispatch'));
    expect(initial.map((t) => t['name']), isNot(contains('bot_probe')));
    gate.allowed = true;
    final listed = await bridge.call({
      ...call('baocode_dispatch'),
      'arguments': {'operation': 'list'},
    }, threadId: 'thread');
    expect(listed['contentItems'].toString(), contains('new capability'));
    final dispatch = {
      ...call('baocode_dispatch'),
      'arguments': {
        'operation': 'call',
        'name': 'bot_probe',
        'arguments': <String, Object?>{},
      },
    };
    expect(
      (await bridge.call(dispatch, threadId: 'thread'))['success'],
      isTrue,
    );
    gate.allowed = false;
    expect(
      (await bridge.call(dispatch, threadId: 'thread'))['success'],
      isFalse,
    );
  });

  test('foreign calls and failed tools cannot claim success', () async {
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'bot_probe',
        description: '',
        inputSchema: {},
        run: (_, _) async => throw StateError('failed'),
      ),
    );
    expect((await bridge.call(call(), threadId: 'other'))['success'], isFalse);
    expect(
      (await bridge.call({
        ...call(),
        'namespace': 'foreign',
      }, threadId: 'thread'))['success'],
      isFalse,
    );
    final result = await bridge.call(call(), threadId: 'thread');
    expect(result['success'], isFalse);
    expect(result['contentItems'].toString(), contains('failed'));
  });

  test(
    'cancellation reaches tools and never reports successful completion',
    () async {
      final started = Completer<void>();
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: 'bot_probe',
          description: '',
          inputSchema: {},
          run: (_, call) async {
            started.complete();
            await call.cancelled;
            return 'stopped';
          },
        ),
      );
      final pending = bridge.call(call(), threadId: 'thread');
      await started.future;
      bridge.cancel();
      expect((await pending)['success'], isFalse);
    },
  );

  test('image and app tool identity survive mobile v1 encoding', () async {
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: ChatCodec.botImageTool,
        description: '',
        inputSchema: {},
        kind: ToolKind.mcp,
        run: (_, _) async => [
          claudeSdkText('picture'),
          claudeSdkImage('AQID', 'image/png'),
        ],
      ),
    );
    final result = await bridge.call(
      call(ChatCodec.botImageTool),
      threadId: 'thread',
    );
    final item = CodexAppTools.item({
      'id': 'call',
      'tool': ChatCodec.botImageTool,
      'arguments': <String, Object?>{},
      'status': 'completed',
      ...result,
    }, done: true);
    expect(item.status, ToolStatus.succeeded);
    expect(item.images.single.bytes, [1, 2, 3]);
    expect(ChatCodec.botSent(item), isTrue);
    expect(item.callId, 'call');
  });

  test(
    'restricted config disables named MCPs/plugins rather than empty merge',
    () {
      final config = CodexAppTools.restrictedConfig({
        'mcp_servers': {
          'external': {'command': 'server'},
        },
        'plugins': {
          'plugin@market': {'enabled': true},
        },
        'apps': {
          'connector': {'enabled': true},
        },
      });
      expect(config['mcp_servers'], {
        'external': {'enabled': false},
      });
      expect((config['plugins'] as Map)['plugin@market'], {'enabled': false});
      expect((config['apps'] as Map)['connector'], {'enabled': false});
      expect((config['features'] as Map)['shell_tool'], isFalse);
      expect(
        CodexAppTools.instructions(
          const KernelWorkspace(
            folders: [],
            ownPrompt: true,
            instructions: 'bot rules',
          ),
        ),
        containsPair('baseInstructions', contains('bot rules')),
      );
    },
  );
}
