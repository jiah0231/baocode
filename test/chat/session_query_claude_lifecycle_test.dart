import 'dart:async';
import 'dart:convert';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/session_query.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

class _Cli extends FakeCli {
  _Cli(this.changed);
  final void Function() changed;

  @override
  void write(Map<String, Object?> message) {
    super.write(message);
    changed();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final finish in [false, true]) {
    test('real Claude provider switch preserves the new selected grant until '
        '${finish ? 'finish' : 'stop'}', () async {
      final changes = StreamController<void>.broadcast();
      void changed() => changes.add(null);
      Future<void> until(bool Function() condition) async {
        if (!condition()) {
          await changes.stream.firstWhere((_) => condition())
              .timeout(const Duration(seconds: 10));
        }
        // Do not reenter a synchronous kernel event dispatch from a waiter.
        await Future<void>(() {});
      }
      final clis = <_Cli>[];
      late final KernelDescriptor descriptor;
      late ClaudeCodeKernel kernel;
      final providers = ModelProviders.memory(providers: const [
        ModelProvider(
          id: 'other', name: 'Other provider',
          protocol: ProviderProtocol.openaiChat,
          baseUrl: 'https://example.invalid/v1',
          models: [ProviderModel(id: 'test-model', contextWindow: 128000)],
        ),
      ]);
      descriptor = KernelDescriptor(
        id: 'claude-code', label: 'Claude Code',
        icon: const IconData(0xe001), description: '',
        create: (context) => kernel = ClaudeCodeKernel(
          descriptor, context, providers: providers,
          providerEnvironment: (_, __) async => {
            'ANTHROPIC_BASE_URL': 'http://127.0.0.1:9/test-proxy',
          },
          start: (_) async {
            final cli = _Cli(changed);
            clis.add(cli);
            changed();
            return cli;
          },
        ),
      );
      var reads = 0;
      final service = SessionQueryService(read: (id) async {
        reads++;
        return SessionQuerySnapshot(
          targetId: id, title: 'Selected Codex', kernel: 'Codex',
          messages: const [
            SessionQueryMessage(index: 0, role: 'assistant', text: 'Host-bound history'),
          ],
        );
      })..register();
      final session = ChatSession(
        kernel: descriptor, kernels: [descriptor], historyCount: 0,
        kernelContext: const KernelContext(cwd: '/project'),
        openReview: (_, {session}) async => null,
      )
        ..sessionQueries = service
        ..canQuerySession = (id) => id == 'codex:target';
      final started = <String>[];
      final ended = <String>[];
      final events = kernel.events.listen((event) {
        if (event case TurnStarted(:final turnId)) started.add(turnId);
        if (event case TurnEnded(:final turnId)) ended.add(turnId);
        changed();
      });
      addTearDown(() async {
        session.dispose();
        service.dispose();
        await events.cancel();
        await Future<void>(() {});
        await changes.close();
      });
      var queryNumber = 0;
      Future<Map> query(_Cli cli) async {
        final id = 'host-query-${++queryNumber}';
        cli.push({
          'type': 'control_request', 'request_id': id,
          'request': {
            'subtype': 'mcp_message',
            'server_name': ClaudeSdkTools.server,
            'message': {
              'jsonrpc': '2.0', 'id': id, 'method': 'tools/call',
              'params': {
                'name': SessionQueryService.toolName,
                // No capability or local turn ID is supplied by the model.
                'arguments': {'session_id': 'codex:target'},
              },
            },
          },
        });
        Map? response() => cli.written.where((message) =>
          message['type'] == 'control_response' &&
          (message['response'] as Map?)?['request_id'] == id,
        ).firstOrNull;
        await until(() => response() != null);
        final envelope = response()!['response'] as Map;
        final payload = envelope['response'] as Map;
        final mcp = payload['mcp_response'] as Map;
        return mcp['result'] as Map;
      }

      session.send(const ComposerMessage(text: 'Keep the original turn running'));
      await until(() => clis.isNotEmpty && clis.single.users.isNotEmpty);
      final original = clis.single;
      original.push({
        'type': 'system', 'subtype': 'init',
        'session_id': 'claude-source', 'cwd': '/project',
      });
      await until(() => session.sessionId == 'claude-source');
      expect(started, hasLength(1));
      final oldTurn = started.single;
      expect((await query(original))['isError'], isTrue);
      expect(reads, 0);

      kernel.model.select('@other/test-model');
      session.send(const ComposerMessage(
        text: 'Read the selected history on the new provider',
        sessionMentions: ['codex:target'],
      ));
      await until(() => clis.length == 2 && clis.last.users.isNotEmpty);
      expect(original.closed, isTrue);
      expect(ended, contains(oldTurn), reason: 'Exercise the synchronous old TurnEnded path.');
      expect(started, hasLength(2));
      expect(started.last, isNot(oldTurn));
      final replacement = clis.last;
      replacement.push({
        'type': 'system', 'subtype': 'init',
        'session_id': 'claude-source', 'cwd': '/project',
      });
      expect(jsonEncode(replacement.users), isNot(matches(r'sq_[0-9a-f]{64}')));
      expect(jsonEncode(replacement.users), isNot(contains('capability=')));
      final answer = await query(replacement);
      expect(answer['isError'], isNot(true));
      expect(answer.toString(), contains('Host-bound history'));
      expect(reads, 1, reason: 'Old TurnEnded must not revoke the pending new grant.');

      final newTurn = started.last;
      if (finish) {
        replacement.push({
          'type': 'result', 'subtype': 'success',
          'session_id': 'claude-source', 'result': '', 'duration_ms': 1,
        });
      } else {
        session.stop();
      }
      await until(() => ended.contains(newTurn));
      expect((await query(replacement))['isError'], isTrue);
      expect(reads, 1, reason: 'Stopped or completed turns cannot read again.');
    });
  }
}
