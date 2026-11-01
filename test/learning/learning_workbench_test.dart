import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/widgets/edit_step.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/learning/learning_bubble.dart';
import 'package:baocode/learning/work_trace_panel.dart';
import 'package:baocode/learning/learning_models.dart';
import 'package:baocode/learning/learning_preferences.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart';

import 'learning_bubble_test.dart'
    show teachingDiff, bubbleLesson, captureBubble;
import 'learning_visual_fonts.dart';

class _Kernel implements AgentKernel {
  _Kernel(this.descriptor, this.events);
  @override
  final KernelDescriptor descriptor;
  @override
  final Stream<KernelEvent> events;
  @override
  KernelHealth get health => const KernelHealth(KernelHealthStatus.ready);
  @override
  String? get sessionId => null;
  @override
  Future<void> get stopped => Future<void>.value();
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
  void dispose() {}
}

class _Generator implements LearningGenerator {
  int calls = 0;
  int explanations = 0;
  int narratives = 0;
  @override
  Future<Map<String, Object?>> generate(
    LearningRequest request,
    LearningCancellation cancellation,
  ) async {
    calls++;
    if (request.kind == LearningRequestKind.narrative) {
      narratives++;
      final facts = request.narrative!.facts;
      return {
        'phases': [
          for (final fact in facts)
            {
              'id': 'phase-${facts.indexOf(fact) + 1}',
              'title': fact.sourceItemId == 'synthetic-diagnostic'
                  ? '调整诊断脚本'
                  : fact.sourceItemId == 'fixture-verify'
                  ? '记录检查结果'
                  : '查看查询方式',
              'summary': fact.sourceItemId == 'synthetic-diagnostic'
                  ? '调整脚本输出标题，并为日志查询增加数量上限。'
                  : fact.sourceItemId == 'fixture-verify'
                  ? '检查命令已执行结束；现有证据不足以确认诊断结果正确。'
                  : '查看诊断脚本，确认需要处理的文件；读取记录本身不能说明脚本内容。',
              'status': 'observed',
              'evidenceIds': [fact.id],
            },
        ],
      };
    }
    explanations++;
    final lesson = bubbleLesson();
    final isDiff = request.evidence.any(
      (e) => e.sourceItemId == 'synthetic-diagnostic',
    );
    if (!isDiff) {
      return {
        'title': '记录操作结果',
        'summary': '观察到检查操作已结束。',
        'why': '结束状态只说明操作完成，不能据此判断诊断结论正确。',
        'concept': '执行状态与结果正确性需要分开验证。',
        'evidenceIds': [request.evidence.first.id],
      };
    }
    return {
      'title': lesson.title,
      'summary': lesson.summary,
      'why': lesson.why,
      'concept': lesson.concept,
      'tradeoff': lesson.tradeoff,
      'evidenceIds': [
        request.evidence
            .firstWhere((e) => e.sourceItemId == 'synthetic-diagnostic')
            .id,
      ],
    };
  }
}

void main() {
  setUpAll(loadLearningVisualFonts);
  for (final theme in ['Bao Dark', 'Bao Light']) {
    for (final width in [1800.0, 1400.0, 600.0]) {
      learningWidgetTest('inline learning actual chat $theme $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        WorkbenchThemeService.instance.restore(setting: theme);
        await tester.runAsync(WorkbenchThemeService.instance.initialize);
        final events = StreamController<KernelEvent>.broadcast(sync: true);
        late final KernelDescriptor descriptor;
        descriptor = KernelDescriptor(
          id: 'fixture',
          label: 'Synthetic agent',
          icon: Icons.code,
          description: '',
          create: (_) => _Kernel(descriptor, events.stream),
        );
        final session = ChatSession(
          kernel: descriptor,
          kernels: [descriptor],
          historyCount: 0,
          kernelContext: const KernelContext(cwd: '/synthetic'),
        );
        final providers = ModelProviders.memory(
          providers: const [
            ModelProvider(
              id: 'synthetic',
              name: 'Synthetic teaching',
              baseUrl: 'https://synthetic.invalid',
              models: [ProviderModel(id: 'teaching')],
            ),
          ],
        );
        final saved = <String, Object?>{
          LearningPreferences.settingKey: <String, Object?>{
            'enabled': true,
            'model': '@synthetic/teaching',
            'consentVersion': 1,
          },
        };
        final preferences = LearningPreferences(
          read: (key) => saved[key],
          write: (key, value) async {
            saved[key] = value;
          },
          providers: providers,
        );
        final generator = _Generator();
        addTearDown(session.dispose);
        addTearDown(events.close);
        addTearDown(preferences.dispose);
        addTearDown(providers.dispose);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Material(
              child: Row(
                children: [
                  Expanded(
                    child: ChatScreen(
                      session: session,
                      title: '诊断脚本 · 合成演示',
                      learningPreferences: preferences,
                      learningGenerator: generator,
                    ),
                  ),
                  if (width == 1800)
                    SizedBox(
                      width: 320,
                      child: WorkTracePanel(
                        controller: session.workTrace,
                        narrative: session.learning,
                        onOpenItem: session.revealOperation,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(generator.calls, 0);
        expect(preferences.needsConsentReview, isTrue);
        if (width == 1800) {
          events.add(const TurnStarted(1, 'before-consent'));
          events.add(
            const ItemUpserted(
              2,
              'local-only',
              TerminalItem(command: 'echo synthetic', output: 'synthetic'),
            ),
          );
          events.add(const TurnEnded(3, 'before-consent'));
          await tester.pumpAndSettle();
          expect(session.workTrace.entries, isNotEmpty);
          expect(generator.calls, 0);
          await tester.tap(find.byKey(const Key('work-trace-evidence')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('查看原操作').first);
          await tester.pump();
          expect(session.operationReveal.value?.id, 'local-only');
          await tester.tap(find.byKey(const Key('work-trace-evidence')));
          await tester.pumpAndSettle();
          events.add(const ItemRemoved(4, 'local-only'));
          await tester.pumpAndSettle();
        }
        await preferences.configure(
          modelRef: '@synthetic/teaching',
          consent: true,
        );
        await tester.pump();
        events.add(const TurnStarted(10, 'fixture-turn'));
        events.add(
          const ItemUpserted(
            11,
            'fixture-request',
            UserMessageItem(text: '检查诊断脚本的日志查询范围。'),
          ),
        );
        events.add(
          const ItemUpserted(
            12,
            'fixture-inspect',
            ToolCallItem(
              kind: ToolKind.read,
              target: 'tm_diag2.ps1',
              path: 'synthetic/tm_diag2.ps1',
              status: ToolStatus.succeeded,
            ),
          ),
        );
        events.add(
          const ItemUpserted(13, 'synthetic-diagnostic', teachingDiff),
        );
        events.add(
          const FileEdited(
            14,
            FileChange(path: 'synthetic/tm_diag2.ps1', added: 2, removed: 2),
            sourceItemId: 'synthetic-diagnostic',
          ),
        );
        events.add(
          const ItemUpserted(
            15,
            'fixture-verify',
            TerminalItem(
              command: 'echo synthetic-check-completed',
              output: 'Synthetic check completed; diagnostic correctness not verified.',
              description: '记录检查命令结束，尚未验证诊断结论（合成示例）',
              status: CommandStatus.succeeded,
            ),
          ),
        );
        events.add(const TurnEnded(16, 'fixture-turn'));
        expect(session.workTrace.entries, hasLength(3));
        expect(
          session.workTrace.entries.map((entry) => entry.sourceItemId),
          containsAll([
            'fixture-inspect',
            'synthetic-diagnostic',
            'fixture-verify',
          ]),
        );
        await tester.pump(const Duration(seconds: 25));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 25));
        await tester.pumpAndSettle();
        for (var tick = 0; tick < 6; tick++) {
          await tester.pump(const Duration(seconds: 25));
          await tester.pumpAndSettle();
        }
        expect(generator.explanations, 2);
        expect(generator.narratives, greaterThanOrEqualTo(1));
        expect(session.learning.narrativePhases, hasLength(3));
        expect(
          session.learning.narrativePhases.map((phase) => phase.summary),
          contains('检查命令已执行结束；现有证据不足以确认诊断结果正确。'),
        );
        session.revealOperation('synthetic-diagnostic');
        await tester.pumpAndSettle();
        expect(find.byType(EditStep), findsOneWidget);
        final diffBubble = find.byWidgetPredicate(
          (widget) =>
              widget is LearningBubble &&
              widget.card.evidence.any(
                (e) => e.sourceItemId == 'synthetic-diagnostic',
              ),
        );
        expect(diffBubble, findsOneWidget);
        final bubbleRect = tester.getRect(diffBubble);
        final diffRect = tester.getRect(find.byType(EditStep));
        expect(bubbleRect.right, lessThanOrEqualTo(width));
        if (find
            .byKey(const Key('learning-operation-row'))
            .evaluate()
            .isNotEmpty) {
          expect(bubbleRect.left, greaterThanOrEqualTo(diffRect.right));
        } else {
          expect(bubbleRect.top, greaterThanOrEqualTo(diffRect.bottom));
        }
        expect(tester.takeException(), isNull);
        await captureBubble(
          tester,
          'chat-inline-${theme.replaceAll(' ', '-')}-${width.toInt()}',
        );
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
