import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/learning/learning_controller.dart';
import 'package:baocode/learning/narrative_models.dart';
import 'package:baocode/learning/work_trace.dart';
import 'package:baocode/learning/work_trace_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Narrative extends LearningController {
  List<NarrativePhase> phases = [];
  bool on = true, loading = false, ended = false;
  String? failure;
  int omitted = 0;
  @override
  int get narrativeOmittedCount => omitted;
  @override
  List<NarrativePhase> get narrativePhases => phases;
  @override
  bool get enabled => on;
  @override
  bool get narrativeBusy => loading;
  @override
  String? get narrativeError => failure;
  @override
  bool get narrativeEnded => ended;
  @override
  String? get narrativeTurnId => 'turn';
  void update() => notifyListeners();
}

const _phase = NarrativePhase(
  id: 'phase-1',
  title: 'Inspect the diagnosis path',
  summary: 'The observed work first inspected the diagnostic script. It then narrowed the log query before checking its output.',
  status: 'observed',
  evidence: [
    NarrativeFact(
      id: 'fact-1',
      kind: 'file',
      label: 'synthetic_diagnostic.ps1',
      status: 'completed',
      sourceItemId: 'exact-source',
    ),
  ],
);

void main() {
  Future<void> pump(
    WidgetTester tester,
    WorkTraceController facts,
    _Narrative narrative, {
    ValueChanged<String>? onOpenItem,
    double width = 360,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 720);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: WorkTracePanel(
              controller: facts,
              narrative: narrative,
              onOpenItem: onOpenItem,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'generated prose is primary; raw facts require explicit expansion',
    (tester) async {
      addTearDown(tester.view.reset);
      final facts = WorkTraceController();
      final narrative = _Narrative()
        ..phases = [_phase]
        ..omitted = 2;
      addTearDown(facts.dispose);
      addTearDown(narrative.dispose);
      facts.accept(const TurnStarted(1, 'turn'));
      facts.accept(
        const FileEdited(
          2,
          FileChange(path: 'synthetic_raw.dart', added: 2, removed: 1),
          turnId: 'turn',
          sourceItemId: 'raw-source',
        ),
      );
      String? opened;
      await pump(tester, facts, narrative, onOpenItem: (id) => opened = id);
      expect(find.text(_phase.summary), findsOneWidget);
      expect(
        find.textContaining('bounded subset of observed steps'),
        findsOneWidget,
      );
      expect(find.textContaining('synthetic_raw.dart'), findsNothing);
      expect(find.text('synthetic_diagnostic.ps1'), findsNothing);
      await tester.tap(
        find.byKey(const Key('work-trace-phase-evidence-phase-1')),
      );
      await tester.pump();
      expect(find.text('synthetic_diagnostic.ps1'), findsOneWidget);
      await tester.tap(find.text('View operation'));
      expect(opened, 'exact-source');
      expect(find.byKey(const Key('work-trace-follow-latest')), findsOneWidget);

      narrative.phases = [
        const NarrativePhase(
          id: 'phase-1',
          title: 'Inspect the diagnosis path',
          summary: 'The same stage now includes the observed output check.',
          status: 'observed',
          evidence: [
            NarrativeFact(
              id: 'fact-1',
              kind: 'file',
              label: 'synthetic_diagnostic.ps1',
              status: 'completed',
              sourceItemId: 'exact-source',
            ),
          ],
        ),
      ];
      narrative.update();
      await tester.pump();
      expect(
        find.byKey(const ValueKey(('work-trace-phase', 'phase-1'))),
        findsOneWidget,
      );
      expect(find.text('synthetic_diagnostic.ps1'), findsOneWidget);
      expect(find.text('Process updated · Follow latest'), findsOneWidget);
    },
  );

  testWidgets('off, loading and errors never become a templated process', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final facts = WorkTraceController();
    final narrative = _Narrative()..on = false;
    addTearDown(facts.dispose);
    addTearDown(narrative.dispose);
    facts.accept(const TurnStarted(1, 'turn'));
    facts.accept(
      const FileEdited(
        2,
        FileChange(path: 'only_raw.dart', added: 1, removed: 0),
        turnId: 'turn',
      ),
    );
    await pump(tester, facts, narrative, width: 280, scale: 1.4);
    expect(find.text('No work process generated yet'), findsOneWidget);
    expect(find.textContaining('only_raw.dart'), findsNothing);
    narrative
      ..on = true
      ..loading = true;
    narrative.update();
    await tester.pump();
    expect(find.text('Organizing the work process…'), findsOneWidget);
    narrative
      ..loading = false
      ..failure = 'private provider error';
    narrative.update();
    await tester.pump();
    expect(find.text('private provider error'), findsNothing);
    expect(find.text('No work process generated yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
