import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/theme/app_theme.dart';

/// Synthetic kernel events pass through the production session and transcript.
/// No saved chats, real CLI, model, network or user data are involved.
class _Kernel implements AgentKernel {
  final controller = StreamController<KernelEvent>.broadcast(sync: true);
  int seq = 0;
  late final KernelDescriptor _descriptor = KernelDescriptor(
    id: 'stream-work-test',
    label: 'Test',
    icon: Icons.code,
    description: '',
    create: (_) => this,
  );
  @override
  KernelDescriptor get descriptor => _descriptor;
  @override
  Stream<KernelEvent> get events => controller.stream;
  @override
  KernelHealth get health => const KernelHealth(KernelHealthStatus.ready);
  @override
  String? get sessionId => null;
  @override
  Future<void> get stopped => Future.value();
  @override
  void send(KernelTurn turn) {}
  @override
  void answer(String requestId, InteractionAnswer answer) {}
  @override
  void cancel() {}
  @override
  void restart() {}
  @override
  void prepare() {}
  @override
  void release() {}
  @override
  void dispose() {
    unawaited(controller.close());
  }

  void seed(int turns) {
    controller.add(
      HistoryPrepended(++seq, [
        for (var n = 0; n < turns; n++) ...[
          ('u$n', UserMessageItem(text: 'Question $n')),
          ('a$n', AssistantTextItem('Answer $n.\n\n- One\n- Two')),
        ],
      ]),
    );
    controller.add(TurnStarted(++seq, 'live'));
    controller.add(
      ItemUpserted(++seq, 'live', const UserMessageItem(text: 'Continue')),
    );
    controller.add(
      ItemUpserted(
        ++seq,
        'reply',
        const AssistantTextItem('Answer'),
        streaming: true,
      ),
    );
  }

  int offset = 6;
  void delta() {
    controller.add(TextDelta(++seq, 'reply', offset, ' word'));
    offset += 5;
  }

  void finish() => controller.add(TurnEnded(++seq, 'live'));
}

class _CountingSession extends ChatSession {
  _CountingSession(_Kernel kernel)
    : super(
        kernel: kernel.descriptor,
        kernels: [kernel.descriptor],
        historyCount: 0,
      );
  int reads = 0;
  @override
  ChatItem itemAt(int index) {
    reads++;
    return super.itemAt(index);
  }
}

void main() {
  for (final semantics in [false, true]) {
    testWidgets('streaming work stays bounded as old history grows '
        '(semantics: $semantics)', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final handle = semantics ? tester.ensureSemantics() : null;
      try {
        final counts = <int>[];
        for (final turns in [20, 2000]) {
          final kernel = _Kernel();
          final session = _CountingSession(kernel);
          kernel.seed(turns);
          expect(session.itemCount, 2 * turns + 3);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(),
              home: Scaffold(
                body: ChatHistoryView(feed: session, minimap: true),
              ),
            ),
          );
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          session.reads = 0;
          for (var i = 0; i < 8; i++) {
            kernel.delta();
            await tester.pump(const Duration(milliseconds: 80));
          }
          final running = session.reads;
          counts.add(running);
          expect(
            find.text('Answer${' word' * 8}', findRichText: true),
            findsOneWidget,
          );
          kernel.finish();
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          session.reads = 0;
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 80));
          }
          final stopped = session.reads;
          // Deterministic work counts, not an FPS claim from a debug test.
          debugPrint(
            'STREAM_WORK turns=$turns semantics=$semantics '
            'runningReads=$running stoppedReads=$stopped',
          );
          expect(stopped, lessThan(50));
          await tester.pumpWidget(const SizedBox());
          session.dispose();
        }
        // 100x more historical turns must not cause 100x work per shown delta.
        expect(counts.last, lessThan(counts.first * 2 + 1000));
        expect(counts.last, lessThan(10000));
      } finally {
        handle?.dispose();
      }
    });
  }
}
