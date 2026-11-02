import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/link/workspace_bridge.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../link/workspace_bridge_test.dart' show peers;

class _Server implements CodexTransport {
  final controller = StreamController<Map<String, Object?>>.broadcast();
  final written = <Map<String, Object?>>[];
  final done = Completer<void>();
  @override
  Stream<Map<String, Object?>> get messages => controller.stream;
  @override
  Future<void> get exited => done.future;
  @override
  void close() {
    if (!controller.isClosed) controller.close();
    if (!done.isCompleted) done.complete();
  }

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    if (message['method'] == null) return;
    final result = switch (message['method']) {
      'initialize' => {'userAgent': 'baocode/0.166.0 (Windows 10; x86_64)'},
      'config/read' => {'config': <String, Object?>{}},
      'thread/start' || 'thread/resume' => {'thread': {'id': 'thread'}},
      'turn/start' => {'turn': {'id': 'turn'}},
      _ => <String, Object?>{},
    };
    scheduleMicrotask(() {
      if (!controller.isClosed) {
        controller.add({'id': message['id'], 'result': result});
      }
    });
  }
}

void main() {
  test('phone explicitly opts a Codex bot in and answers its approval', () async {
    final servers = <_Server>[];
    late final KernelDescriptor codex;
    codex = KernelDescriptor(
      id: 'codex',
      label: 'Codex',
      icon: Icons.code,
      description: '',
      create: (context) {
        final server = _Server();
        servers.add(server);
        return CodexKernel.withTransport(codex, server, context: context);
      },
    );
    final workspace = Workspace(kernels: [MockKernels.claudeCode, codex]);
    final bots = Bots(
      workspace: workspace,
      folders: MemoryBotFolders(),
      computer: () async => 'Test',
    );
    final (phone, desktop) = await peers();
    final bridge = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(
        name: 'Test', kind: 'windows', system: 'Windows',
      ),
      bots: bots,
    );
    addTearDown(() {
      bridge.dispose();
      bots.dispose();
      workspace.dispose();
      phone.close();
    });
    await workspace.load();
    await bots.start();
    bots.setKernel(bots.bots.single, 'codex');
    final bot = bots.bots.single;
    expect(bot.chatOnly, isTrue);
    expect(bridge.state().bots.single.chatOnly, isTrue);
    final patch = <String, Object?>{
      'bot': bot.id,
      'name': bot.name,
      'identity': bot.identity,
      'abilities': bot.abilities.map((a) => a.name).toList(),
    };
    // Old clients omitting the new field cannot expand the boundary.
    await bridge.handle(LinkMethods.saveBot, patch);
    expect(bots.byId(bot.id)!.chatOnly, isTrue);
    await bridge.handle(LinkMethods.saveBot, {...patch, 'chatOnly': false});
    expect(bridge.state().bots.single.chatOnly, isFalse);
    final reply = await bridge.handle(LinkMethods.send, {
      'bot': bot.id, 'text': 'Make the requested change',
    }) as Map;
    await pumpEventQueue(times: 100);
    final server = servers.lastWhere(
      (s) => s.written.any((m) => m['method'] == 'turn/start'),
    );
    final start = server.written.firstWhere(
      (m) => m['method'] == 'thread/start',
    )['params'] as Map;
    expect(start['sandbox'], 'workspace-write');
    expect(start['approvalPolicy'], 'on-request');
    void request(int id) => server.controller.add({
      'id': id,
      'method': 'item/commandExecution/requestApproval',
      'params': {
        'threadId': 'thread', 'turnId': 'turn',
        'command': 'needed-command', 'reason': 'Needs approval',
      },
    });
    request(901);
    await pumpEventQueue();
    final session = reply['session'];
    Future<LinkSessionUpdate> open() async => LinkSessionUpdate.fromJson(
      await bridge.handle(LinkMethods.open, {'session': session})
          as Map<String, Object?>,
    );
    final snapshot = await open();
    expect(snapshot.interaction, containsPair('t', 'approval'));
    expect(snapshot.interaction, containsPair('id', 'approval:901'));
    expect(bridge.state().bots.single.notices, hasLength(1));
    final notice = bridge.state().bots.single.notices.single;
    expect(notice.kind, 'waiting');
    expect(notice.detail, contains('supports approvals'));
    expect(notice.detail, contains('cancel'));
    // A real kernel notification while the same approval is pending
    // must not repeat its notice.
    server.controller.add({
      'method': 'thread/name/updated',
      'params': {'threadId': 'thread', 'threadName': 'Awaiting approval'},
    });
    await pumpEventQueue();
    expect(bridge.state().bots.single.notices, hasLength(1));
    await bridge.handle(LinkMethods.answer, {
      'session': session, 'request': 'approval:901',
      'answer': {'t': 'approval', 'decision': 'allowOnce'},
    });
    expect(server.written.lastWhere((m) => m['id'] == 901)['result'],
        {'decision': 'accept'});
    expect(bots.threadFor(bots.byId(bot.id)!).session.pendingInteraction, isNull);
    request(902);
    await pumpEventQueue();
    await expectLater(bridge.handle(LinkMethods.answer, {
      'session': session, 'request': 'approval:901',
      'answer': {'t': 'approval', 'decision': 'allowOnce'},
    }), throwsA(isA<LinkRemoteException>()));
    expect(bots.threadFor(bots.byId(bot.id)!).session.pendingInteraction?.id,
        'approval:902');
    expect(server.written.where((m) => m['id'] == 902), isEmpty);
    await bridge.handle(LinkMethods.answer, {
      'session': session, 'request': 'approval:902',
      'answer': {'t': 'approval', 'decision': 'deny'},
    });
    expect(server.written.lastWhere((m) => m['id'] == 902)['result'],
        {'decision': 'decline'});
    expect(bots.threadFor(bots.byId(bot.id)!).session.pendingInteraction, isNull);
    request(903);
    await pumpEventQueue();
    expect(bridge.state().bots.single.notices, hasLength(3));
    await bridge.handle(LinkMethods.stop, {'session': session});
    await pumpEventQueue();
    expect(server.written.any((m) => m['method'] == 'turn/interrupt'), isTrue);
    expect(bots.threadFor(bots.byId(bot.id)!).session.pendingInteraction, isNull);
    expect(server.written.where((m) => m['id'] == 903 &&
        m['result'] is Map &&
        (m['result'] as Map)['decision'] == 'accept'), isEmpty);
  });
}
