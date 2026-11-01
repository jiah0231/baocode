import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/side_panel/side_panel_controller.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/learning/learning_models.dart';
import 'package:baocode/learning/learning_controller.dart';
import 'package:baocode/learning/learning_preferences.dart';
import 'package:baocode/learning/learning_session_view.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ScopeGenerator implements LearningGenerator {
  final requests = <LearningRequest>[];
  final cancellations = <LearningCancellation>[];
  Completer<Map<String, Object?>>? pending;

  Map<String, Object?> answer(LearningRequest request) => {
    'title': 'Input validation',
    'summary': 'The observed command completed.',
    'why': 'It may check the changed code; intent is not known.',
    'concept': 'A completed check is evidence, not proof of every behavior.',
    'evidenceIds': [request.evidence.first.id],
  };

  @override
  Future<Map<String, Object?>> generate(
    LearningRequest request,
    LearningCancellation cancellation,
  ) async {
    requests.add(request);
    cancellations.add(cancellation);
    return pending == null ? answer(request) : pending!.future;
  }
}

class StatusController extends LearningController {
  StatusController({this.failure = false, this.limited = false});
  final bool failure, limited;
  @override
  bool get enabled => true;
  @override
  String? get error => failure ? 'private raw provider error' : null;
  @override
  bool get budgetReached => limited;
}

void main() {
  late ModelProviders providers;
  late LearningPreferences preferences;
  late ScopeGenerator generator;
  late ChatSession session;

  setUp(() {
    providers = ModelProviders.memory(
      providers: const [
        ModelProvider(
          id: 'synthetic',
          name: 'Synthetic provider',
          models: [ProviderModel(id: 'teaching')],
        ),
      ],
    );
    preferences = LearningPreferences.memory(providers: providers);
    generator = ScopeGenerator();
    session = ChatSession(
      historyCount: 8,
      kernelContext: const KernelContext(cwd: '/synthetic/project'),
    );
  });
  tearDown(() {
    session.dispose();
    preferences.dispose();
    providers.dispose();
  });

  Future<void> enable() =>
      preferences.configure(modelRef: '@synthetic/teaching', consent: true);
  void observe(ChatSession task, int seq) => task.learning.observe(
    ItemUpserted(
      seq,
      'synthetic-operation-$seq',
      TerminalItem(
        command: 'flutter test synthetic_$seq.dart',
        output: 'Passed',
      ),
    ),
  );
  Widget host({ChatSession? task, bool active = true, Widget? child}) =>
      MaterialApp(
        home: LearningSessionBinding(
          session: task ?? session,
          active: active,
          preferences: preferences,
          generator: generator,
          child: child ?? const SizedBox(),
        ),
      );

  testWidgets('mounted chat starts disabled and enabling never reads history', (
    tester,
  ) async {
    LearningScope? scope;
    await tester.pumpWidget(
      host(
        child: Builder(
          builder: (context) {
            scope = LearningScope.of(context);
            return const LearningControls();
          },
        ),
      ),
    );
    expect(session.learning.active, isTrue);
    expect(session.learning.enabled, isFalse);
    observe(session, 1);
    await tester.pump(const Duration(seconds: 25));
    expect(generator.requests, isEmpty);
    await enable();
    await tester.pump();
    expect(session.learning.enabled, isTrue);
    await tester.pump(const Duration(seconds: 25));
    expect(
      generator.requests,
      isEmpty,
      reason: 'Existing history and pre-consent events never become requests',
    );
    observe(session, 2);
    await tester.pump(const Duration(seconds: 25));
    await tester.pump();
    expect(generator.requests, hasLength(1));
    expect(scope!.cardForItem('synthetic-operation-2'), isNotNull);
    expect(scope!.cardForItem('synthetic-operation-1'), isNull);
    expect(scope!.cardForItem('/synthetic/project'), isNull);
    expect(scope!.modelLabel, 'Synthetic provider · teaching');
    await tester.pumpWidget(const SizedBox());
    expect(session.learning.active, isFalse);
    // Host-owned preferences remain usable after the binding leaves.
    expect(preferences.enabled, isTrue);
  });

  testWidgets(
    'hidden task cancels immediately and does not accumulate backlog',
    (tester) async {
      await enable();
      generator.pending = Completer<Map<String, Object?>>();
      await tester.pumpWidget(host());
      observe(session, 1);
      await tester.pump(const Duration(seconds: 25));
      expect(generator.requests, hasLength(1));
      await tester.pumpWidget(host(active: false));
      expect(session.learning.active, isFalse);
      expect(generator.cancellations.single.isCancelled, isTrue);
      observe(session, 2);
      await tester.pump(const Duration(seconds: 25));
      generator.pending!.complete(generator.answer(generator.requests.single));
      generator.pending = null;
      await tester.pump();
      expect(session.learning.cards, isEmpty);
      await tester.pumpWidget(host());
      await tester.pump(const Duration(seconds: 25));
      expect(generator.requests, hasLength(1));
      observe(session, 3);
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
      expect(generator.requests, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('reusing binding for another task cancels the prior task', (
    tester,
  ) async {
    final other = ChatSession(
      kernelContext: const KernelContext(cwd: '/synthetic/project'),
    );
    addTearDown(other.dispose);
    await enable();
    generator.pending = Completer<Map<String, Object?>>();
    await tester.pumpWidget(host());
    observe(session, 1);
    await tester.pump(const Duration(seconds: 25));
    await tester.pumpWidget(host(task: other));
    expect(session.learning.active, isFalse);
    expect(other.learning.active, isTrue);
    expect(generator.cancellations.single.isCancelled, isTrue);
    generator.pending!.complete(generator.answer(generator.requests.single));
    generator.pending = null;
    await tester.pump();
    expect(session.learning.cards, isEmpty);
    await tester.pump(const Duration(seconds: 25));
    expect(generator.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    expect(other.learning.active, isFalse);
  });

  for (final limited in [false, true]) {
    testWidgets(
      'compact controls show safe ${limited ? 'budget' : 'error'} status and keep pause available',
      (tester) async {
        final controller = StatusController(
          failure: !limited,
          limited: limited,
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: 160,
                child: LearningScope(
                  controller: controller,
                  preferences: preferences,
                  modelLabel: 'Synthetic model',
                  child: const LearningControls(),
                ),
              ),
            ),
          ),
        );
        expect(
          find.text(limited ? 'Session limit reached' : 'Learning unavailable'),
          findsOneWidget,
        );
        expect(find.textContaining('private raw provider error'), findsNothing);
        expect(find.text('Pause learning'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Pause learning'));
        await tester.pump();
        expect(find.text('Resume learning'), findsOneWidget);
        expect(controller.paused, isTrue);
        expect(
          tester.getSize(find.byType(LearningControls)).width,
          lessThanOrEqualTo(280),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('legacy side panel never activates teaching', (tester) async {
    final panel = AgentSidePanel();
    addTearDown(panel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: LearningSessionView(session: session, panel: panel),
      ),
    );
    expect(session.learning.active, isFalse);
    expect(session.learning.enabled, isFalse);
    expect(generator.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('one view leaving does not deactivate another visible owner', (
    tester,
  ) async {
    Widget view(String key) => LearningSessionBinding(
      key: ValueKey(key),
      session: session,
      preferences: preferences,
      generator: generator,
      child: const SizedBox(),
    );
    await tester.pumpWidget(
      MaterialApp(home: Column(children: [view('one'), view('two')])),
    );
    expect(session.learning.active, isTrue);
    await tester.pumpWidget(MaterialApp(home: Column(children: [view('two')])));
    expect(session.learning.active, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(session.learning.active, isFalse);
  });
}
